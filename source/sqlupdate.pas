unit sqlupdate;

interface

uses
  System.Classes;

function SqlMonitorCheckAndApplyClientUpdate(AOwner: TComponent; const CurrentVersion: String;
  CurrentRevision: Integer; const CurrentBuildLabel: String): Boolean;

implementation

uses
  System.SysUtils, System.JSON, System.StrUtils, System.Hash, System.Math, Winapi.Windows, Winapi.ShellAPI,
  Vcl.Forms, Vcl.Dialogs, Vcl.Controls, Vcl.StdCtrls,
  apphelpers, sqlmonitor;

{$I const.inc}

const
  UPDATE_STATUS_OK_VISIBLE_MS = 1800;

type
  TClientUpdateInfo = record
    UpdateAvailable: Boolean;
    Mandatory: Boolean;
    Version: String;
    Revision: Integer;
    Commit: String;
    DownloadUrl: String;
    FileName: String;
    PackageType: String;
    Sha256: String;
    Size: Int64;
    ReleaseNotes: String;
  end;

function ShowUpdateStatusDialog(const StatusText: String): TForm;
var
  StatusLabel: TLabel;
begin
  Result := TForm.CreateNew(Application);
  Result.BorderStyle := bsDialog;
  Result.BorderIcons := [];
  Result.Caption := SqlMonitorTranslate('HeidiSQL CSLOG update');
  Result.Position := poScreenCenter;
  Result.ClientWidth := 430;
  Result.ClientHeight := 92;

  StatusLabel := TLabel.Create(Result);
  StatusLabel.Name := 'lblStatus';
  StatusLabel.Parent := Result;
  StatusLabel.Left := 18;
  StatusLabel.Top := 18;
  StatusLabel.Width := Result.ClientWidth - 36;
  StatusLabel.Height := 52;
  StatusLabel.AutoSize := False;
  StatusLabel.WordWrap := True;
  StatusLabel.Caption := StatusText;

  Result.Show;
  Result.Update;
  Application.ProcessMessages;
end;


procedure SetUpdateStatusDialogText(StatusForm: TForm; const StatusText: String);
var
  StatusLabel: TComponent;
begin
  if not Assigned(StatusForm) then
    Exit;
  StatusLabel := StatusForm.FindComponent('lblStatus');
  if StatusLabel is TLabel then
    TLabel(StatusLabel).Caption := StatusText;
  StatusForm.Update;
  Application.ProcessMessages;
end;


procedure CloseUpdateStatusDialog(var StatusForm: TForm);
begin
  if not Assigned(StatusForm) then
    Exit;
  StatusForm.Close;
  FreeAndNil(StatusForm);
  Application.ProcessMessages;
end;


procedure SleepWithMessagePump(DurationMs: Cardinal);
var
  Deadline: UInt64;
begin
  Deadline := GetTickCount64 + DurationMs;
  while GetTickCount64 < Deadline do begin
    Application.ProcessMessages;
    Sleep(50);
  end;
end;

function GetClientHostName: String;
var
  Buffer: array[0..MAX_COMPUTERNAME_LENGTH + 1] of Char;
  BufferSize: DWORD;
begin
  BufferSize := Length(Buffer);
  if GetComputerName(Buffer, BufferSize) then
    SetString(Result, Buffer, BufferSize)
  else
    Result := '';
end;


function ExtractClientCommit(const BuildLabel: String): String;
var
  Parts: TArray<String>;
  LabelText: String;
begin
  Result := '';
  LabelText := Trim(BuildLabel);
  if LabelText.IsEmpty or (Pos('%', LabelText) > 0) then
    Exit;
  Parts := LabelText.Split([' '], TStringSplitOptions.ExcludeEmpty);
  if Length(Parts) > 0 then
    Result := Parts[High(Parts)];
end;


function BuildUpdateCheckPayload(const CurrentVersion: String; CurrentRevision: Integer;
  const CurrentBuildLabel: String): String;
var
  RootJson: TJSONObject;
begin
  RootJson := TJSONObject.Create;
  try
    RootJson.AddPair('client_app', APPNAME);
    RootJson.AddPair('client_version', CurrentVersion);
    RootJson.AddPair('client_revision', TJSONNumber.Create(CurrentRevision));
    RootJson.AddPair('client_build_label', CurrentBuildLabel);
    RootJson.AddPair('client_commit', ExtractClientCommit(CurrentBuildLabel));
    RootJson.AddPair('client_host', GetClientHostName);
    RootJson.AddPair('platform', 'windows');
    RootJson.AddPair('arch', 'x64');
    RootJson.AddPair('channel', 'stable');
    Result := RootJson.ToJSON;
  finally
    RootJson.Free;
  end;
end;


function JsonString(JsonObject: TJSONObject; const Name: String; const DefaultValue: String=''): String;
var
  Value: TJSONValue;
begin
  Result := DefaultValue;
  Value := JsonObject.GetValue(Name);
  if Assigned(Value) then
    Result := Value.Value;
end;


function JsonBool(JsonObject: TJSONObject; const Name: String; DefaultValue: Boolean=False): Boolean;
var
  Value: TJSONValue;
  Text: String;
begin
  Result := DefaultValue;
  Value := JsonObject.GetValue(Name);
  if not Assigned(Value) then
    Exit;
  Text := LowerCase(Trim(Value.Value));
  if (Text = 'true') or (Text = '1') then
    Result := True
  else if (Text = 'false') or (Text = '0') then
    Result := False;
end;


function JsonInt(JsonObject: TJSONObject; const Name: String; DefaultValue: Integer=0): Integer;
var
  Value: TJSONValue;
begin
  Result := DefaultValue;
  Value := JsonObject.GetValue(Name);
  if Assigned(Value) then
    Result := StrToIntDef(Value.Value, DefaultValue);
end;


function JsonInt64(JsonObject: TJSONObject; const Name: String; DefaultValue: Int64=0): Int64;
var
  Value: TJSONValue;
begin
  Result := DefaultValue;
  Value := JsonObject.GetValue(Name);
  if Assigned(Value) then
    Result := StrToInt64Def(Value.Value, DefaultValue);
end;


function ParseUpdateCheckResponse(const JsonText: String): TClientUpdateInfo;
var
  JsonValue: TJSONValue;
  JsonObject: TJSONObject;
begin
  FillChar(Result, SizeOf(Result), 0);
  JsonValue := TJSONObject.ParseJSONValue(JsonText);
  try
    if not (JsonValue is TJSONObject) then
      raise Exception.Create(SqlMonitorTranslate('The central service returned an invalid update payload.'));
    JsonObject := TJSONObject(JsonValue);
    Result.UpdateAvailable := JsonBool(JsonObject, 'update_available', False);
    Result.Mandatory := JsonBool(JsonObject, 'mandatory', False);
    Result.Version := JsonString(JsonObject, 'version');
    Result.Revision := JsonInt(JsonObject, 'revision', 0);
    Result.Commit := JsonString(JsonObject, 'commit');
    Result.DownloadUrl := JsonString(JsonObject, 'download_url');
    Result.FileName := JsonString(JsonObject, 'filename');
    Result.PackageType := LowerCase(JsonString(JsonObject, 'package_type', 'exe'));
    Result.Sha256 := LowerCase(JsonString(JsonObject, 'sha256'));
    Result.Size := JsonInt64(JsonObject, 'size', 0);
    Result.ReleaseNotes := JsonString(JsonObject, 'release_notes');
  finally
    JsonValue.Free;
  end;
end;


function CombineUrl(const BaseUrl, RelativeUrl: String): String;
begin
  if StartsText('http://', RelativeUrl) or StartsText('https://', RelativeUrl) then
    Exit(RelativeUrl);
  Result := BaseUrl.TrimRight(['/']) + '/' + RelativeUrl.TrimLeft(['/']);
end;


procedure AddMonitorHeaders(Http: THttpDownload; const Accept: String);
var
  AuthToken: String;
begin
  Http.RequestHeaders.Values['Accept'] := Accept;
  Http.RequestHeaders.Values['X-API-Key'] := SqlMonitorGetApiKey;
  AuthToken := SqlMonitorGetCurrentAuthToken;
  if not AuthToken.IsEmpty then
    Http.RequestHeaders.Values['Authorization'] := 'Bearer ' + AuthToken;
end;


function FetchUpdateInfo(AOwner: TComponent; const CurrentVersion: String; CurrentRevision: Integer;
  const CurrentBuildLabel: String): TClientUpdateInfo;
var
  Http: THttpDownload;
  ResponseText, StatusText: String;
begin
  Http := THttpDownload.Create(AOwner);
  try
    Http.URL := TSqlMonitorClient.BaseUrl + '/v1/client-updates/check';
    Http.Method := 'POST';
    Http.TimeOut := TSqlMonitorClient.SessionTimeoutSeconds;
    Http.RequestHeaders.Values['Content-Type'] := 'application/json';
    AddMonitorHeaders(Http, 'application/json');
    Http.RequestBody := BuildUpdateCheckPayload(CurrentVersion, CurrentRevision, CurrentBuildLabel);
    Http.SendRequest('');
    ResponseText := Http.LastContent;
    if (Http.StatusCode < 200) or (Http.StatusCode > 299) then begin
      StatusText := Trim(ResponseText);
      if StatusText.IsEmpty then
        StatusText := Format('HTTP status %d', [Http.StatusCode]);
      raise ESqlMonitorHttpError.Create(Http.StatusCode, StatusText);
    end;
    Result := ParseUpdateCheckResponse(ResponseText);
  finally
    Http.Free;
  end;
end;


function SafeUpdateFileName(const UpdateInfo: TClientUpdateInfo): String;
begin
  Result := ExtractFileName(UpdateInfo.FileName);
  if Result.IsEmpty then
    Result := 'heidisql-cslog-update.' + IfThen(UpdateInfo.PackageType = 'zip', 'zip', 'exe');
end;


function DownloadUpdatePackage(AOwner: TComponent; const UpdateInfo: TClientUpdateInfo;
  const UpdateDir: String): String;
var
  Http: THttpDownload;
  ExpectedHash, ActualHash, DownloadUrl, StatusText: String;
begin
  if UpdateInfo.DownloadUrl.IsEmpty then
    raise Exception.Create(SqlMonitorTranslate('The central service did not return an update download URL.'));

  ForceDirectories(UpdateDir);
  Result := IncludeTrailingPathDelimiter(UpdateDir) + SafeUpdateFileName(UpdateInfo);
  if FileExists(Result) then
    System.SysUtils.DeleteFile(Result);

  DownloadUrl := CombineUrl(TSqlMonitorClient.BaseUrl, UpdateInfo.DownloadUrl);
  Http := THttpDownload.Create(AOwner);
  try
    Http.URL := DownloadUrl;
    Http.Method := 'GET';
    Http.TimeOut := Max(120, TSqlMonitorClient.SessionTimeoutSeconds);
    AddMonitorHeaders(Http, 'application/octet-stream');
    Http.SendRequest(Result);
    if (Http.StatusCode < 200) or (Http.StatusCode > 299) then begin
      if FileExists(Result) then
        System.SysUtils.DeleteFile(Result);
      StatusText := Format('HTTP status %d', [Http.StatusCode]);
      raise ESqlMonitorHttpError.Create(Http.StatusCode, StatusText);
    end;
  finally
    Http.Free;
  end;

  if not FileExists(Result) then
    raise Exception.CreateFmt('Downloaded file not found: %s', [Result]);
  if (UpdateInfo.Size > 0) and (_GetFileSize(Result) <> UpdateInfo.Size) then
    raise Exception.CreateFmt('Downloaded file corrupted: %s', [Result]);

  ExpectedHash := LowerCase(Trim(UpdateInfo.Sha256));
  if not ExpectedHash.IsEmpty then begin
    ActualHash := LowerCase(THashSHA2.GetHashStringFromFile(Result, THashSHA2.TSHA2Version.SHA256));
    if ActualHash <> ExpectedHash then begin
      System.SysUtils.DeleteFile(Result);
      raise Exception.Create(SqlMonitorTranslate('The downloaded HeidiSQL CSLOG update failed integrity validation.'));
    end;
  end;
end;


function PowerShellQuote(const Value: String): String;
begin
  Result := '''' + StringReplace(Value, '''', '''''', [rfReplaceAll]) + '''';
end;


function WriteUpdaterScript(const UpdateInfo: TClientUpdateInfo; const PackagePath, UpdateDir: String): String;
var
  Lines: TStringList;
  TargetExe, TargetDir, PackageType: String;
begin
  TargetExe := Application.ExeName;
  TargetDir := ExtractFilePath(TargetExe);
  PackageType := LowerCase(UpdateInfo.PackageType);
  if PackageType.IsEmpty then
    PackageType := LowerCase(Copy(ExtractFileExt(PackagePath), 2, MaxInt));
  if PackageType.IsEmpty then
    PackageType := 'exe';

  Result := IncludeTrailingPathDelimiter(UpdateDir) + 'apply-heidisql-cslog-update.ps1';
  Lines := TStringList.Create;
  try
    Lines.Add('$ErrorActionPreference = ''Stop''');
    Lines.Add('$targetExe = ' + PowerShellQuote(TargetExe));
    Lines.Add('$targetDir = ' + PowerShellQuote(ExcludeTrailingPathDelimiter(TargetDir)));
    Lines.Add('$package = ' + PowerShellQuote(PackagePath));
    Lines.Add('$packageType = ' + PowerShellQuote(PackageType));
    Lines.Add('$pidToWait = ' + IntToStr(GetCurrentProcessId));
    Lines.Add('try { Wait-Process -Id $pidToWait -ErrorAction SilentlyContinue -Timeout 60 } catch { }');
    Lines.Add('Start-Sleep -Seconds 1');
    Lines.Add('if ($packageType -eq ''zip'') {');
    Lines.Add('  Expand-Archive -LiteralPath $package -DestinationPath $targetDir -Force');
    Lines.Add('} else {');
    Lines.Add('  Copy-Item -LiteralPath $package -Destination $targetExe -Force');
    Lines.Add('}');
    Lines.Add('Start-Process -FilePath $targetExe');
    Lines.SaveToFile(Result, TEncoding.UTF8);
  finally
    Lines.Free;
  end;
end;


procedure LaunchUpdaterScript(const ScriptPath: String);
var
  Params: String;
  ShellResult: HINST;
begin
  Params := '-NoProfile -ExecutionPolicy Bypass -File ' + AnsiQuotedStr(ScriptPath, '"');
  ShellResult := ShellExecute(0, 'runas', 'powershell.exe', PChar(Params), nil, SW_HIDE);
  if NativeInt(ShellResult) <= 32 then
    raise Exception.CreateFmt('Unable to start elevated updater. ShellExecute returned %d.', [NativeInt(ShellResult)]);
end;


function ConfirmUpdate(const UpdateInfo: TClientUpdateInfo; const CurrentVersion: String): Boolean;
var
  MessageText, Notes: String;
begin
  Notes := Trim(UpdateInfo.ReleaseNotes);
  if Notes.IsEmpty then
    Notes := SqlMonitorTranslate('No release notes were provided.');

  if UpdateInfo.Mandatory then
    MessageText := Format(SqlMonitorTranslate('A mandatory HeidiSQL CSLOG update is available.'),
      [CurrentVersion, UpdateInfo.Version, Notes])
  else
    MessageText := Format(SqlMonitorTranslate('A new HeidiSQL CSLOG version is available.'),
      [CurrentVersion, UpdateInfo.Version, Notes]);

  MessageDialog(MessageText, mtInformation, [mbOK]);
  Result := True;
end;


function SqlMonitorCheckAndApplyClientUpdate(AOwner: TComponent; const CurrentVersion: String;
  CurrentRevision: Integer; const CurrentBuildLabel: String): Boolean;
var
  UpdateInfo: TClientUpdateInfo;
  UpdateDir, PackagePath, ScriptPath: String;
  StatusForm: TForm;
begin
  Result := False;
  if (not CSLOG_BUILD) or (not TSqlMonitorClient.IsConfigured) then
    Exit;

  StatusForm := nil;
  try
    StatusForm := ShowUpdateStatusDialog(SqlMonitorTranslate('Checking for HeidiSQL CSLOG updates...'));
    UpdateInfo := FetchUpdateInfo(AOwner, CurrentVersion, CurrentRevision, CurrentBuildLabel);
    if not UpdateInfo.UpdateAvailable then begin
      SetUpdateStatusDialogText(StatusForm, SqlMonitorTranslate('HeidiSQL CSLOG is up to date.'));
      SleepWithMessagePump(UPDATE_STATUS_OK_VISIBLE_MS);
      CloseUpdateStatusDialog(StatusForm);
      Exit;
    end;

    CloseUpdateStatusDialog(StatusForm);
    if not ConfirmUpdate(UpdateInfo, CurrentVersion) then
      Exit;

    StatusForm := ShowUpdateStatusDialog(SqlMonitorTranslate('Downloading HeidiSQL CSLOG update...'));
    Screen.Cursor := crHourGlass;
    try
      UpdateDir := IncludeTrailingPathDelimiter(GetTempDir) + 'HeidiSQL-CSLOG-update-' +
        StringReplace(UpdateInfo.Version, '.', '-', [rfReplaceAll]);
      PackagePath := DownloadUpdatePackage(AOwner, UpdateInfo, UpdateDir);
      SetUpdateStatusDialogText(StatusForm, SqlMonitorTranslate('Preparing HeidiSQL CSLOG update installation...'));
      ScriptPath := WriteUpdaterScript(UpdateInfo, PackagePath, UpdateDir);
    finally
      Screen.Cursor := crDefault;
    end;

    CloseUpdateStatusDialog(StatusForm);
    MessageDialog(SqlMonitorTranslate('HeidiSQL CSLOG update was downloaded and will be installed now.'),
      mtInformation, [mbOK]);
    LaunchUpdaterScript(ScriptPath);
    Application.Terminate;
    Result := True;
  except
    on E: Exception do begin
      CloseUpdateStatusDialog(StatusForm);
      MessageDialog(SqlMonitorTranslate('Unable to install HeidiSQL CSLOG update: ') + E.Message,
        mtWarning, [mbOK]);
      Result := False;
    end;
  end;
  CloseUpdateStatusDialog(StatusForm);
end;

end.
