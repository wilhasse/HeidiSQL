unit sqlcatalog;

interface

uses
  System.Classes;

function SqlMonitorSyncConnectionCatalog(Manual: Boolean; out SummaryMessage: String): Boolean;

implementation

uses
  Winapi.Windows, System.SysUtils, System.StrUtils, System.Types, System.Generics.Collections,
  System.Generics.Defaults, System.JSON, apphelpers, dbconnection, dbstructures,
  Main, sqlmonitor;

{$I const.inc}

type
  TSqlCatalogItem = class(TObject)
  public
    ConnectionId: String;
    Customer: String;
    BaseName: String;
    EnvironmentName: String;
    Qualifier: String;
    Host: String;
    Port: Integer;
    DatabaseName: String;
    NetType: String;
    DbUser: String;
    Comment: String;
    SortOrder: Integer;
    Enabled: Boolean;
    FolderName: String;
    DisplayName: String;
  end;

  TSqlCatalogItemList = TObjectList<TSqlCatalogItem>;

  TSqlCatalogResponse = class(TObject)
  private
    FConnections: TSqlCatalogItemList;
  public
    CatalogVersion: String;
    constructor Create;
    destructor Destroy; override;
    property Connections: TSqlCatalogItemList read FConnections;
  end;

  TSqlExistingSession = class(TObject)
  public
    SessionPath: String;
    ApiConnectionId: String;
    ApiCustomer: String;
    MatchHost: String;
    MatchDatabases: TStringList;
    Managed: Boolean;
    Archived: Boolean;
    Handled: Boolean;
    constructor Create;
    destructor Destroy; override;
  end;

  TStringDictionary = TDictionary<String, String>;
  TStringSet = TDictionary<String, Boolean>;

const
  ARCHIVE_ROOT_FOLDER = 'OBSOLETAS API';

constructor TSqlCatalogResponse.Create;
begin
  inherited Create;
  FConnections := TSqlCatalogItemList.Create(True);
end;


destructor TSqlCatalogResponse.Destroy;
begin
  FConnections.Free;
  inherited;
end;


constructor TSqlExistingSession.Create;
begin
  inherited Create;
  MatchDatabases := TStringList.Create;
  MatchDatabases.CaseSensitive := False;
  MatchDatabases.Duplicates := dupIgnore;
end;


destructor TSqlExistingSession.Destroy;
begin
  MatchDatabases.Free;
  inherited;
end;


function NormalizeMatchPart(const Value: String): String;
begin
  Result := LowerCase(Trim(Value));
end;


function MakeMatchKey(const HostName, DatabaseName: String): String;
begin
  Result := NormalizeMatchPart(HostName) + #1 + NormalizeMatchPart(DatabaseName);
end;


function SanitizeSessionPathPart(const Value: String): String;
var
  ResultText: String;
begin
  ResultText := Trim(Value);
  ResultText := StringReplace(ResultText, '\', ' - ', [rfReplaceAll]);
  ResultText := StringReplace(ResultText, '/', ' - ', [rfReplaceAll]);
  ResultText := StringReplace(ResultText, #13, ' ', [rfReplaceAll]);
  ResultText := StringReplace(ResultText, #10, ' ', [rfReplaceAll]);
  ResultText := StringReplace(ResultText, #9, ' ', [rfReplaceAll]);
  while Pos('  ', ResultText) > 0 do
    ResultText := StringReplace(ResultText, '  ', ' ', [rfReplaceAll]);
  Result := Trim(ResultText);
end;


function LastPathSegment(const SessionPath: String): String;
var
  Parts: TStringDynArray;
begin
  Parts := SplitString(SessionPath, '\');
  if Length(Parts) = 0 then
    Result := SessionPath
  else
    Result := Parts[High(Parts)];
end;


function StoredSessionDatabase(Params: TConnectionParameters): String;
var
  Databases: TStringList;
begin
  Result := '';
  if not Assigned(Params) then
    Exit;
  Databases := Params.AllDatabasesList;
  try
    if Databases.Count = 1 then
      Result := Trim(Databases[0]);
  finally
    Databases.Free;
  end;
end;


procedure FillStoredSessionDatabases(Params: TConnectionParameters; Databases: TStrings);
var
  StoredDatabases: TStringList;
  i: Integer;
  DatabaseName: String;
begin
  if (not Assigned(Params)) or (Databases = nil) then
    Exit;
  StoredDatabases := Params.AllDatabasesList;
  try
    for i := 0 to StoredDatabases.Count - 1 do begin
      DatabaseName := NormalizeMatchPart(StoredDatabases[i]);
      if (not DatabaseName.IsEmpty) and (Databases.IndexOf(DatabaseName) = -1) then
        Databases.Add(DatabaseName);
    end;
  finally
    StoredDatabases.Free;
  end;
end;


function GetCatalogClientHostName: String;
var
  BufferSize: DWORD;
begin
  BufferSize := MAX_COMPUTERNAME_LENGTH + 1;
  SetLength(Result, BufferSize);
  if GetComputerName(PChar(Result), BufferSize) then
    SetLength(Result, BufferSize)
  else
    Result := '';
end;


function ReadSessionStringSetting(const SessionPath: String; Setting: TAppSettingIndex): String;
begin
  Result := '';
  AppSettings.StorePath;
  try
    if not AppSettings.SessionPathExists(SessionPath) then
      Exit;
    AppSettings.SessionPath := SessionPath;
    Result := AppSettings.ReadString(Setting);
  finally
    AppSettings.RestorePath;
  end;
end;


function ReadSessionBoolSetting(const SessionPath: String; Setting: TAppSettingIndex): Boolean;
begin
  Result := False;
  AppSettings.StorePath;
  try
    if not AppSettings.SessionPathExists(SessionPath) then
      Exit;
    AppSettings.SessionPath := SessionPath;
    Result := AppSettings.ReadBool(Setting);
  finally
    AppSettings.RestorePath;
  end;
end;


procedure WriteSessionStringSetting(const SessionPath: String; Setting: TAppSettingIndex; const Value: String);
begin
  AppSettings.StorePath;
  try
    AppSettings.SessionPath := SessionPath;
    AppSettings.WriteString(Setting, Value);
  finally
    AppSettings.RestorePath;
  end;
end;


procedure WriteSessionBoolSetting(const SessionPath: String; Setting: TAppSettingIndex; Value: Boolean);
begin
  AppSettings.StorePath;
  try
    AppSettings.SessionPath := SessionPath;
    AppSettings.WriteBool(Setting, Value);
  finally
    AppSettings.RestorePath;
  end;
end;


procedure EnsureFolderExists(const FolderPath: String);
var
  Parts: TStringDynArray;
  CurrentPath, Part: String;
  FolderParams: TConnectionParameters;
  i: Integer;
begin
  if Trim(FolderPath).IsEmpty then
    Exit;
  Parts := SplitString(FolderPath, '\');
  CurrentPath := '';
  for i := Low(Parts) to High(Parts) do begin
    Part := SanitizeSessionPathPart(Parts[i]);
    if Part.IsEmpty then
      Continue;
    if CurrentPath.IsEmpty then
      CurrentPath := Part
    else
      CurrentPath := CurrentPath + '\' + Part;
    if not AppSettings.SessionPathExists(CurrentPath) then begin
      FolderParams := TConnectionParameters.Create;
      try
        FolderParams.IsFolder := True;
        FolderParams.SessionPath := CurrentPath;
        FolderParams.SaveToRegistry;
      finally
        FolderParams.Free;
      end;
    end;
  end;
end;


function EnsureUniqueSessionPath(const DesiredPath, CurrentPath: String): String;
var
  ParentPath, NamePart: String;
  Suffix: Integer;
begin
  Result := DesiredPath;
  if Result.IsEmpty then
    Exit;
  if SameText(Result, CurrentPath) then
    Exit;
  if not AppSettings.SessionPathExists(Result) then
    Exit;

  ParentPath := ExtractFileDir(Result).Replace('/', '\');
  if SameText(ParentPath, '.') then
    ParentPath := '';
  NamePart := LastPathSegment(Result);
  Suffix := 2;
  repeat
    if ParentPath <> '' then
      Result := ParentPath + '\' + NamePart + ' ' + IntToStr(Suffix)
    else
      Result := NamePart + ' ' + IntToStr(Suffix);
    Inc(Suffix);
  until (not AppSettings.SessionPathExists(Result)) or SameText(Result, CurrentPath);
end;


procedure MoveSessionPath(var Params: TConnectionParameters; const TargetPath: String);
begin
  if Trim(TargetPath).IsEmpty then
    Exit;
  if Params.SessionPath.IsEmpty then begin
    Params.SessionPath := TargetPath;
    Exit;
  end;
  if SameText(Params.SessionPath, TargetPath) then
    Exit;
  AppSettings.StorePath;
  try
    AppSettings.SessionPath := Params.SessionPath;
    AppSettings.MoveCurrentKey(REGKEY_SESSIONS + '\' + TargetPath);
  finally
    AppSettings.RestorePath;
  end;
  Params.SessionPath := TargetPath;
end;


procedure UpdateSessionMetadata(const SessionPath: String; const ConnectionId, HostName, DatabaseName,
  CustomerName, SyncStamp: String; Archived: Boolean);
begin
  WriteSessionBoolSetting(SessionPath, asApiManaged, True);
  WriteSessionStringSetting(SessionPath, asApiConnectionId, ConnectionId);
  WriteSessionStringSetting(SessionPath, asApiMatchHost, HostName);
  WriteSessionStringSetting(SessionPath, asApiMatchDatabase, DatabaseName);
  WriteSessionStringSetting(SessionPath, asApiCustomer, CustomerName);
  WriteSessionStringSetting(SessionPath, asApiLastSyncAt, SyncStamp);
  WriteSessionBoolSetting(SessionPath, asApiArchived, Archived);
end;


procedure UpdateLastSessionReferences(RenameMap: TStringDictionary; RemovedPaths: TStringSet);
var
  LastSessions, UpdatedSessions: TStringList;
  LastActiveSession, CurrentPath, EffectivePath, MappedPath: String;
  i: Integer;
begin
  LastSessions := Explode(DELIM, AppSettings.ReadString(asLastSessions));
  UpdatedSessions := TStringList.Create;
  try
    for i := 0 to LastSessions.Count - 1 do begin
      CurrentPath := LastSessions[i];
      EffectivePath := CurrentPath;
      if RenameMap.TryGetValue(CurrentPath, MappedPath) then
        EffectivePath := MappedPath;
      if RemovedPaths.ContainsKey(CurrentPath) or RemovedPaths.ContainsKey(EffectivePath) then
        Continue;
      if UpdatedSessions.IndexOf(EffectivePath) = -1 then
        UpdatedSessions.Add(EffectivePath);
    end;
    AppSettings.WriteString(asLastSessions, Implode(DELIM, UpdatedSessions));

    LastActiveSession := AppSettings.ReadString(asLastActiveSession);
    EffectivePath := LastActiveSession;
    if RenameMap.TryGetValue(LastActiveSession, MappedPath) then
      EffectivePath := MappedPath;
    if RemovedPaths.ContainsKey(LastActiveSession) or RemovedPaths.ContainsKey(EffectivePath) then
      EffectivePath := '';
    AppSettings.WriteString(asLastActiveSession, EffectivePath);
  finally
    LastSessions.Free;
    UpdatedSessions.Free;
  end;
end;


function BuildCatalogPayload: String;
var
  RootJson: TJSONObject;
begin
  RootJson := TJSONObject.Create;
  try
    RootJson.AddPair('client_app', APPNAME);
    if Assigned(MainForm) then
      RootJson.AddPair('client_version', MainForm.AppVersion)
    else
      RootJson.AddPair('client_version', '');
    RootJson.AddPair('client_host', GetCatalogClientHostName);
    Result := RootJson.ToJSON;
  finally
    RootJson.Free;
  end;
end;


function GetJsonString(Obj: TJSONObject; const Name: String): String;
var
  Value: TJSONValue;
begin
  Result := '';
  if Obj = nil then
    Exit;
  Value := Obj.GetValue(Name);
  if Value <> nil then
    Result := Value.Value.Trim;
end;


function GetJsonBool(Obj: TJSONObject; const Name: String; DefaultValue: Boolean=False): Boolean;
var
  Value: TJSONValue;
begin
  Result := DefaultValue;
  if Obj = nil then
    Exit;
  Value := Obj.GetValue(Name);
  if Value is TJSONBool then
    Result := TJSONBool(Value).AsBoolean
  else if Value <> nil then
    Result := SameText(Value.Value, 'true') or (Value.Value = '1');
end;


function GetJsonInt(Obj: TJSONObject; const Name: String; DefaultValue: Integer=0): Integer;
var
  Value: TJSONValue;
begin
  Result := DefaultValue;
  if Obj = nil then
    Exit;
  Value := Obj.GetValue(Name);
  if Value <> nil then
    Result := StrToIntDef(Value.Value, DefaultValue);
end;


function ParseApiErrorMessage(const JsonText: String): String;
var
  RootValue: TJSONValue;
  RootObject: TJSONObject;
begin
  Result := '';
  if JsonText.Trim.IsEmpty then
    Exit;
  RootValue := TJSONObject.ParseJSONValue(JsonText);
  if not (RootValue is TJSONObject) then begin
    RootValue.Free;
    Exit;
  end;
  RootObject := RootValue as TJSONObject;
  try
    Result := GetJsonString(RootObject, 'error');
    if Result.IsEmpty then
      Result := GetJsonString(RootObject, 'message');
  finally
    RootValue.Free;
  end;
end;


function SendCatalogRequest(out ResponseText: String): Integer;
var
  Http: THttpDownload;
  StatusText, AuthToken: String;
begin
  Http := THttpDownload.Create(nil);
  try
    Http.URL := TSqlMonitorClient.BaseUrl + '/v1/connections/catalog';
    Http.Method := 'POST';
    Http.TimeOut := TSqlMonitorClient.SessionTimeoutSeconds;
    Http.RequestHeaders.Values['Content-Type'] := 'application/json; charset=utf-8';
    Http.RequestHeaders.Values['Accept'] := 'application/json';
    Http.RequestHeaders.Values['X-API-Key'] := SqlMonitorGetApiKey;
    AuthToken := SqlMonitorGetCurrentAuthToken;
    if not AuthToken.IsEmpty then
      Http.RequestHeaders.Values['Authorization'] := 'Bearer ' + AuthToken;
    Http.RequestBody := BuildCatalogPayload;
    Http.SendRequest('');
    ResponseText := Http.LastContent;
    Result := Http.StatusCode;
    if (Result < 200) or (Result > 299) then begin
      StatusText := ParseApiErrorMessage(ResponseText);
      if StatusText.IsEmpty then
        StatusText := Format('HTTP status %d', [Result]);
      raise ESqlMonitorHttpError.Create(Result, StatusText);
    end;
  finally
    Http.Free;
  end;
end;


function MapCatalogNetType(const Value: String; out NetType: TNetType): Boolean;
var
  TextValue: String;
  NumericValue: Integer;
begin
  TextValue := LowerCase(Trim(Value));
  NumericValue := StrToIntDef(TextValue, -1);
  if NumericValue >= Ord(Low(TNetType)) then begin
    if NumericValue <= Ord(High(TNetType)) then begin
      NetType := TNetType(NumericValue);
      Exit(True);
    end;
  end;

  if (Pos('sqlite', TextValue) > 0) or (Pos('sql server', TextValue) > 0) or (Pos('postgres', TextValue) > 0) then
    Exit(False);
  if Pos('ssh', TextValue) > 0 then
    NetType := ntMySQL_SSHtunnel
  else if Pos('named pipe', TextValue) > 0 then
    NetType := ntMySQL_NamedPipe
  else if Pos('proxysql', TextValue) > 0 then
    NetType := ntMySQL_ProxySQLAdmin
  else if Pos('rds', TextValue) > 0 then
    NetType := ntMySQL_RDS
  else if (Pos('mysql', TextValue) > 0) or (Pos('mariadb', TextValue) > 0) or TextValue.IsEmpty then
    NetType := ntMySQL_TCPIP
  else
    Exit(False);
  Result := True;
end;


function BuildDisplayName(Item: TSqlCatalogItem): String;
var
  Parts: TStringList;
begin
  if not Trim(Item.DisplayName).IsEmpty then
    Exit(SanitizeSessionPathPart(Item.DisplayName));
  Parts := TStringList.Create;
  try
    if not Trim(Item.Customer).IsEmpty then
      Parts.Add(SanitizeSessionPathPart(Item.Customer));
    if not Trim(Item.BaseName).IsEmpty then
      Parts.Add(SanitizeSessionPathPart(Item.BaseName));
    if not Trim(Item.EnvironmentName).IsEmpty then
      Parts.Add(SanitizeSessionPathPart(Item.EnvironmentName));
    if not Trim(Item.Qualifier).IsEmpty then
      Parts.Add(SanitizeSessionPathPart(Item.Qualifier));
    Result := StringReplace(Trim(Parts.Text), sLineBreak, ' - ', [rfReplaceAll]);
    if Result.EndsWith(' - ') then
      Result := Result.Substring(0, Result.Length - 3);
  finally
    Parts.Free;
  end;
end;


function BuildFolderName(Item: TSqlCatalogItem): String;
begin
  if not Trim(Item.FolderName).IsEmpty then
    Result := SanitizeSessionPathPart(Item.FolderName)
  else
    Result := SanitizeSessionPathPart(Item.Customer);
end;


function ParseCatalogResponse(const JsonText: String): TSqlCatalogResponse;
var
  RootValue, ConnectionsValue, ItemValue: TJSONValue;
  RootObject, ItemObject: TJSONObject;
  CatalogItem: TSqlCatalogItem;
  ConnectionIds, MatchKeys: TStringSet;
  MatchKey: String;
  DummyNetType: TNetType;
begin
  Result := TSqlCatalogResponse.Create;
  if JsonText.Trim.IsEmpty then
    Exit;

  RootValue := TJSONObject.ParseJSONValue(JsonText);
  if not (RootValue is TJSONObject) then begin
    RootValue.Free;
    raise Exception.Create(SqlMonitorTranslate('The central service returned an invalid session catalog payload.'));
  end;

  ConnectionIds := TStringSet.Create;
  MatchKeys := TStringSet.Create;
  try
    RootObject := RootValue as TJSONObject;
    Result.CatalogVersion := GetJsonString(RootObject, 'catalog_version');
    ConnectionsValue := RootObject.GetValue('connections');
    if not (ConnectionsValue is TJSONArray) then
      raise Exception.Create(SqlMonitorTranslate('The central service returned an invalid session catalog payload.'));

    for ItemValue in TJSONArray(ConnectionsValue) do begin
      if not (ItemValue is TJSONObject) then
        Continue;
      ItemObject := ItemValue as TJSONObject;
      CatalogItem := TSqlCatalogItem.Create;
      CatalogItem.ConnectionId := GetJsonString(ItemObject, 'connection_id');
      CatalogItem.Customer := GetJsonString(ItemObject, 'customer');
      CatalogItem.BaseName := GetJsonString(ItemObject, 'base');
      CatalogItem.EnvironmentName := GetJsonString(ItemObject, 'environment');
      CatalogItem.Qualifier := GetJsonString(ItemObject, 'qualifier');
      CatalogItem.Host := GetJsonString(ItemObject, 'host');
      CatalogItem.Port := GetJsonInt(ItemObject, 'port', 3306);
      CatalogItem.DatabaseName := GetJsonString(ItemObject, 'database');
      CatalogItem.NetType := GetJsonString(ItemObject, 'net_type');
      CatalogItem.DbUser := GetJsonString(ItemObject, 'db_user');
      CatalogItem.Comment := GetJsonString(ItemObject, 'comment');
      CatalogItem.SortOrder := GetJsonInt(ItemObject, 'sort_order', 0);
      CatalogItem.Enabled := GetJsonBool(ItemObject, 'enabled', True);
      CatalogItem.FolderName := GetJsonString(ItemObject, 'folder_name');
      CatalogItem.DisplayName := GetJsonString(ItemObject, 'display_name');

      if CatalogItem.ConnectionId.IsEmpty or CatalogItem.Customer.IsEmpty or CatalogItem.BaseName.IsEmpty
        or CatalogItem.EnvironmentName.IsEmpty or CatalogItem.Host.IsEmpty
        or CatalogItem.DatabaseName.IsEmpty or (CatalogItem.Port <= 0) then
        raise Exception.Create(SqlMonitorTranslate('The central service returned an incomplete session catalog entry.'));
      if not MapCatalogNetType(CatalogItem.NetType, DummyNetType) then
        raise Exception.CreateFmt(SqlMonitorTranslate('The central service returned an unsupported network type for catalog entry "%s".'), [CatalogItem.ConnectionId]);

      MatchKey := MakeMatchKey(CatalogItem.Host, CatalogItem.DatabaseName);
      if ConnectionIds.ContainsKey(CatalogItem.ConnectionId) or MatchKeys.ContainsKey(MatchKey) then
        raise Exception.Create(SqlMonitorTranslate('The central service returned an invalid session catalog payload.'));
      ConnectionIds.Add(CatalogItem.ConnectionId, True);
      MatchKeys.Add(MatchKey, True);
      if CatalogItem.Enabled then
        Result.Connections.Add(CatalogItem)
      else
        CatalogItem.Free;
    end;
  finally
    ConnectionIds.Free;
    MatchKeys.Free;
    RootValue.Free;
  end;
end;


function FetchCatalogResponse: TSqlCatalogResponse;
var
  ResponseText: String;
  RetryLogin: Boolean;
begin
  RetryLogin := True;
  while True do begin
    if not SqlMonitorEnsureCentralAuthSession('') then
      raise Exception.Create('Centralized AD authentication was cancelled by the user.');
    try
      SendCatalogRequest(ResponseText);
      Exit(ParseCatalogResponse(ResponseText));
    except
      on E: ESqlMonitorHttpError do begin
        if RetryLogin and (E.StatusCode = 401) then begin
          SqlMonitorClearCentralAuthSession;
          RetryLogin := False;
          if not SqlMonitorEnsureCentralAuthSession(SqlMonitorTranslate('Centralized AD session expired. Sign in again to continue.')) then
            raise Exception.Create('Centralized AD authentication was cancelled by the user.');
          Continue;
        end;
        raise;
      end;
    end;
  end;
end;


function LoadExistingSessions: TObjectList<TSqlExistingSession>;
var
  SessionPaths: TStringList;
  SessionPath: String;
  Params: TConnectionParameters;
  Item: TSqlExistingSession;
begin
  Result := TObjectList<TSqlExistingSession>.Create(True);
  SessionPaths := TStringList.Create;
  try
    AppSettings.GetSessionPaths('', SessionPaths);
    for SessionPath in SessionPaths do begin
      Params := TConnectionParameters.Create(SessionPath);
      try
        if Params.IsFolder then
          Continue;
        Item := TSqlExistingSession.Create;
        Item.SessionPath := SessionPath;
        Item.ApiConnectionId := ReadSessionStringSetting(SessionPath, asApiConnectionId);
        Item.ApiCustomer := ReadSessionStringSetting(SessionPath, asApiCustomer);
        Item.MatchHost := NormalizeMatchPart(Params.Hostname);
        FillStoredSessionDatabases(Params, Item.MatchDatabases);
        Item.Managed := ReadSessionBoolSetting(SessionPath, asApiManaged);
        Item.Archived := ReadSessionBoolSetting(SessionPath, asApiArchived);
        Item.Handled := False;
        Result.Add(Item);
      finally
        Params.Free;
      end;
    end;
  finally
    SessionPaths.Free;
  end;
end;


function FindManagedSessionByConnectionId(ExistingSessions: TObjectList<TSqlExistingSession>; const ConnectionId: String): TSqlExistingSession;
var
  Item: TSqlExistingSession;
begin
  Result := nil;
  for Item in ExistingSessions do begin
    if Item.Handled then
      Continue;
    if Item.Managed and SameText(Item.ApiConnectionId, ConnectionId) then
      Exit(Item);
  end;
end;


function PickWinner(Candidates: TObjectList<TSqlExistingSession>; const PreferredPath: String): TSqlExistingSession;
var
  Item: TSqlExistingSession;
begin
  Result := nil;
  for Item in Candidates do begin
    if Item.Managed and (not Item.Archived) then begin
      Result := Item;
      if SameText(Item.SessionPath, PreferredPath) then
        Exit;
    end;
  end;
  if Result = nil then begin
    for Item in Candidates do begin
      if SameText(Item.SessionPath, PreferredPath) then
        Exit(Item);
    end;
  end;
  if Result = nil then begin
    for Item in Candidates do begin
      if (Result = nil) or (AnsiCompareText(Item.SessionPath, Result.SessionPath) < 0) then
        Result := Item;
    end;
  end;
end;


procedure CollectByMatchKey(ExistingSessions: TObjectList<TSqlExistingSession>; const MatchKey: String;
  Candidates: TObjectList<TSqlExistingSession>);
var
  DelimPos: Integer;
  Item: TSqlExistingSession;
  HostName, DatabaseName: String;
begin
  DelimPos := Pos(#1, MatchKey);
  if DelimPos > 0 then begin
    HostName := Copy(MatchKey, 1, DelimPos - 1);
    DatabaseName := Copy(MatchKey, DelimPos + 1, MaxInt);
  end else begin
    HostName := MatchKey;
    DatabaseName := '';
  end;

  for Item in ExistingSessions do begin
    if Item.Handled then
      Continue;
    if SameText(Item.MatchHost, HostName) and (Item.MatchDatabases.IndexOf(DatabaseName) > -1) then
      Candidates.Add(Item);
  end;
end;


procedure DeleteSessionPath(const SessionPath: String);
begin
  if Trim(SessionPath).IsEmpty then
    Exit;
  AppSettings.StorePath;
  try
    if not AppSettings.SessionPathExists(SessionPath) then
      Exit;
    AppSettings.SessionPath := SessionPath;
    AppSettings.DeleteCurrentKey;
  finally
    AppSettings.RestorePath;
  end;
end;


function ParentSessionPath(const SessionPath: String): String;
var
  DelimPos: Integer;
begin
  DelimPos := LastDelimiter('\', SessionPath);
  if DelimPos > 0 then
    Result := Copy(SessionPath, 1, DelimPos - 1)
  else
    Result := '';
end;


procedure DeleteEmptyFolderChain(const FolderPath: String);
var
  CurrentPath: String;
begin
  CurrentPath := Trim(FolderPath);
  if CurrentPath.IsEmpty then
    Exit;

  AppSettings.StorePath;
  try
    while not CurrentPath.IsEmpty do begin
      if not AppSettings.SessionPathExists(CurrentPath) then begin
        CurrentPath := ParentSessionPath(CurrentPath);
        Continue;
      end;
      AppSettings.SessionPath := CurrentPath;
      if not AppSettings.IsEmptyKey then
        Break;
      AppSettings.DeleteCurrentKey;
      CurrentPath := ParentSessionPath(CurrentPath);
    end;
  finally
    AppSettings.RestorePath;
  end;
end;


procedure CleanupEmptyArchiveFolders(RemovedPaths: TStringSet);
var
  RemovedPath, FolderPath: String;
begin
  if RemovedPaths = nil then
    Exit;

  for RemovedPath in RemovedPaths.Keys do begin
    FolderPath := ParentSessionPath(RemovedPath);
    if FolderPath.IsEmpty then
      Continue;
    if SameText(FolderPath, ARCHIVE_ROOT_FOLDER) or StartsText(ARCHIVE_ROOT_FOLDER + '\', FolderPath) then
      DeleteEmptyFolderChain(FolderPath);
  end;

  DeleteEmptyFolderChain(ARCHIVE_ROOT_FOLDER);
end;


function ShouldDeleteArchivedSession(SessionRef: TSqlExistingSession; ActiveCatalogKeys: TStringSet): Boolean;
var
  DatabaseName: String;
begin
  Result := False;
  if (SessionRef = nil) or (ActiveCatalogKeys = nil) then
    Exit;
  if SessionRef.MatchDatabases.Count <= 1 then
    Exit;

  for DatabaseName in SessionRef.MatchDatabases do begin
    if ActiveCatalogKeys.ContainsKey(MakeMatchKey(SessionRef.MatchHost, DatabaseName)) then
      Exit(True);
  end;
end;


function ArchiveSession(SessionRef: TSqlExistingSession; RemovedPaths: TStringSet; ActiveCatalogKeys: TStringSet;
  const SyncStamp: String): String;
var
  Params: TConnectionParameters;
  CustomerFolder, ArchiveFolder, TargetPath, OldPath: String;
begin
  Result := SessionRef.SessionPath;
  OldPath := SessionRef.SessionPath;

  if ShouldDeleteArchivedSession(SessionRef, ActiveCatalogKeys) then begin
    DeleteSessionPath(OldPath);
    RemovedPaths.AddOrSetValue(OldPath, True);
    SessionRef.SessionPath := '';
    SessionRef.Archived := True;
    SessionRef.Handled := True;
    Exit('');
  end;

  Params := TConnectionParameters.Create(SessionRef.SessionPath);
  try
    CustomerFolder := SanitizeSessionPathPart(SessionRef.ApiCustomer);
    if CustomerFolder.IsEmpty then
      CustomerFolder := SanitizeSessionPathPart(LastPathSegment(ExtractFileDir(SessionRef.SessionPath)));
    ArchiveFolder := ARCHIVE_ROOT_FOLDER;
    if not CustomerFolder.IsEmpty then
      ArchiveFolder := ArchiveFolder + '\' + CustomerFolder;
    EnsureFolderExists(ArchiveFolder);
    TargetPath := ArchiveFolder + '\' + SanitizeSessionPathPart(LastPathSegment(SessionRef.SessionPath));
    TargetPath := EnsureUniqueSessionPath(TargetPath, SessionRef.SessionPath);
    MoveSessionPath(Params, TargetPath);
    Params.SaveToRegistry;
    UpdateSessionMetadata(Params.SessionPath, SessionRef.ApiConnectionId, Params.Hostname,
      StoredSessionDatabase(Params), CustomerFolder, SyncStamp, True);
    RemovedPaths.AddOrSetValue(OldPath, True);
    SessionRef.SessionPath := Params.SessionPath;
    SessionRef.Archived := True;
    SessionRef.Handled := True;
    Result := Params.SessionPath;
  finally
    Params.Free;
  end;
end;


function SortCatalogItems(const Left, Right: TSqlCatalogItem): Integer;
begin
  Result := Left.SortOrder - Right.SortOrder;
  if Result <> 0 then
    Exit;
  Result := AnsiCompareText(Left.Customer, Right.Customer);
  if Result <> 0 then
    Exit;
  Result := AnsiCompareText(Left.BaseName, Right.BaseName);
  if Result <> 0 then
    Exit;
  Result := AnsiCompareText(Left.EnvironmentName, Right.EnvironmentName);
  if Result <> 0 then
    Exit;
  Result := AnsiCompareText(Left.Qualifier, Right.Qualifier);
end;


function SqlMonitorSyncConnectionCatalog(Manual: Boolean; out SummaryMessage: String): Boolean;
var
  Catalog: TSqlCatalogResponse;
  ExistingSessions: TObjectList<TSqlExistingSession>;
  Candidates: TObjectList<TSqlExistingSession>;
  Item: TSqlCatalogItem;
  Winner, Candidate: TSqlExistingSession;
  Params: TConnectionParameters;
  MatchKey, FolderName, DisplayName, DesiredPath, FinalPath, PreviousPath, SyncStamp: String;
  RenameMap: TStringDictionary;
  RemovedPaths: TStringSet;
  ActiveCatalogKeys: TStringSet;
  CatalogNetType: TNetType;
  CreatedCount, UpdatedCount, ArchivedCount: Integer;
begin
  Result := False;
  SummaryMessage := '';
  if not SqlMonitorCentralAuthEnabled then begin
    SummaryMessage := SqlMonitorTranslate('Connection catalog synchronization requires centralized AD authentication.');
    Exit;
  end;
  if not TSqlMonitorClient.IsConfigured then begin
    SummaryMessage := SqlMonitorTranslate('Connection catalog synchronization requires the SQL monitor URL and API key.');
    Exit;
  end;

  Catalog := nil;
  ExistingSessions := nil;
  Candidates := TObjectList<TSqlExistingSession>.Create(False);
  RenameMap := TStringDictionary.Create;
  RemovedPaths := TStringSet.Create;
  ActiveCatalogKeys := TStringSet.Create;
  CreatedCount := 0;
  UpdatedCount := 0;
  ArchivedCount := 0;
  SyncStamp := FormatDateTime('yyyy-mm-dd"T"hh:nn:ss', Now);
  try
    Catalog := FetchCatalogResponse;
    Catalog.Connections.Sort(TComparer<TSqlCatalogItem>.Construct(SortCatalogItems));
    for Item in Catalog.Connections do
      ActiveCatalogKeys.AddOrSetValue(MakeMatchKey(Item.Host, Item.DatabaseName), True);
    ExistingSessions := LoadExistingSessions;

    for Item in Catalog.Connections do begin
      if not MapCatalogNetType(Item.NetType, CatalogNetType) then
        raise Exception.CreateFmt(SqlMonitorTranslate('The central service returned an unsupported network type for catalog entry "%s".'), [Item.ConnectionId]);

      FolderName := BuildFolderName(Item);
      DisplayName := BuildDisplayName(Item);
      EnsureFolderExists(FolderName);
      if FolderName.IsEmpty then
        DesiredPath := DisplayName
      else
        DesiredPath := FolderName + '\' + DisplayName;
      MatchKey := MakeMatchKey(Item.Host, Item.DatabaseName);

      Winner := FindManagedSessionByConnectionId(ExistingSessions, Item.ConnectionId);
      Candidates.Clear;
      CollectByMatchKey(ExistingSessions, MatchKey, Candidates);
      if (Winner = nil) and (Candidates.Count > 0) then
        Winner := PickWinner(Candidates, DesiredPath);

      for Candidate in Candidates do begin
        if Candidate <> Winner then begin
          ArchiveSession(Candidate, RemovedPaths, ActiveCatalogKeys, SyncStamp);
          Inc(ArchivedCount);
        end;
      end;

      if Assigned(Winner) then
        Params := TConnectionParameters.Create(Winner.SessionPath)
      else
        Params := TConnectionParameters.Create;
      try
        PreviousPath := Params.SessionPath;
        Params.IsFolder := False;
        Params.NetType := CatalogNetType;
        if Params.LibraryOrProvider.IsEmpty or (Params.LibraryOrProvider <> Params.DefaultLibrary) then
          Params.LibraryOrProvider := Params.DefaultLibrary;
        Params.Hostname := Item.Host;
        Params.Port := Item.Port;
        Params.Username := Item.DbUser;
        Params.AllDatabasesStr := Item.DatabaseName;
        Params.Comment := Item.Comment;
        Params.SSHActive := CatalogNetType = ntMySQL_SSHtunnel;

        FinalPath := EnsureUniqueSessionPath(DesiredPath, Params.SessionPath);
        MoveSessionPath(Params, FinalPath);
        Params.SaveToRegistry;
        UpdateSessionMetadata(Params.SessionPath, Item.ConnectionId, Item.Host, Item.DatabaseName,
          FolderName, SyncStamp, False);

        if Assigned(Winner) then begin
          Winner.SessionPath := Params.SessionPath;
          Winner.ApiConnectionId := Item.ConnectionId;
          Winner.ApiCustomer := FolderName;
          Winner.MatchHost := NormalizeMatchPart(Item.Host);
          Winner.MatchDatabases.Clear;
          Winner.MatchDatabases.Add(NormalizeMatchPart(Item.DatabaseName));
          Winner.Managed := True;
          Winner.Archived := False;
          Winner.Handled := True;
          Inc(UpdatedCount);
        end else
          Inc(CreatedCount);

        if (not PreviousPath.IsEmpty) and (not SameText(PreviousPath, Params.SessionPath)) then
          RenameMap.AddOrSetValue(PreviousPath, Params.SessionPath);
      finally
        Params.Free;
      end;
    end;

    for Winner in ExistingSessions do begin
      if Winner.Handled or (not Winner.Managed) or Winner.Archived then
        Continue;
      ArchiveSession(Winner, RemovedPaths, ActiveCatalogKeys, SyncStamp);
      Inc(ArchivedCount);
    end;

    UpdateLastSessionReferences(RenameMap, RemovedPaths);
    CleanupEmptyArchiveFolders(RemovedPaths);
    if (CreatedCount = 0) and (UpdatedCount = 0) and (ArchivedCount = 0) then
      SummaryMessage := SqlMonitorTranslate('Session catalog synchronized successfully.')
    else
      SummaryMessage := Format(SqlMonitorTranslate('Session catalog synchronized: %d created, %d updated, %d archived.'), [CreatedCount, UpdatedCount, ArchivedCount]);
    Result := True;
  except
    on E: Exception do begin
      SummaryMessage := SqlMonitorTranslate('Session catalog synchronization failed: ') + E.Message;
      Result := False;
    end;
  end;

  Candidates.Free;
  RenameMap.Free;
  RemovedPaths.Free;
  ActiveCatalogKeys.Free;
  ExistingSessions.Free;
  Catalog.Free;
end;

end.