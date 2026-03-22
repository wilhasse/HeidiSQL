unit sqlmonitor;

interface

uses
  System.Classes, System.SysUtils, System.Generics.Collections, System.JSON,
  Winapi.Windows, Vcl.Forms, dbconnection;

type
  ESqlMonitorError = class(Exception);

  TSqlMonitorBatchStatus = (smbsUnknown, smbsLogged, smbsPending, smbsApproved, smbsRejected, smbsCancelled, smbsError);
  TSqlMonitorStatementKind = (smskUnknown, smskSelect, smskInsert, smskUpdate, smskDelete, smskOther);
  TSqlMonitorStatementDecision = (smsdUnknown, smsdLogged, smsdPending, smsdApproved, smsdRejected, smsdCancelled);

  TSqlMonitorStatementInfo = class(TObject)
  public
    Index: Integer;
    SQL: String;
    Kind: TSqlMonitorStatementKind;
    Decision: TSqlMonitorStatementDecision;
    Reason: String;
    EstimatedRows: Int64;
  end;

  TSqlMonitorStatementInfoList = TObjectList<TSqlMonitorStatementInfo>;

  TSqlMonitorBatchResponse = class(TObject)
  private
    FStatements: TSqlMonitorStatementInfoList;
  public
    RequestId: String;
    Status: TSqlMonitorBatchStatus;
    RequiresPolling: Boolean;
    ErrorMessage: String;
    constructor Create;
    destructor Destroy; override;
    function DecisionReason: String;
    function HasGuardedWrites: Boolean;
    property Statements: TSqlMonitorStatementInfoList read FStatements;
  end;

  TSqlMonitorStatementExecution = class(TObject)
  public
    StatementIndex: Integer;
    SQL: String;
    Executed: Boolean;
    Success: Boolean;
    DurationMs: Cardinal;
    RowsAffected: Int64;
    RowsFound: Int64;
    ErrorMessage: String;
    constructor Create(AStatementIndex: Integer; const ASQL: String);
  end;

  TSqlMonitorStatementExecutionList = TObjectList<TSqlMonitorStatementExecution>;

  TSqlMonitorExecutionContext = class(TObject)
  private
    FRequestId: String;
    FStatements: TSqlMonitorStatementExecutionList;
  public
    constructor Create(const ARequestId: String; StatementSql: TStrings);
    destructor Destroy; override;
    procedure MarkStatementResult(StatementIndex: Integer; Success: Boolean; DurationMs: Cardinal;
      RowsAffected, RowsFound: Int64; const ErrorMessage: String);
    procedure SendCompletion(Connection: TDBConnection; TotalDurationMs: Cardinal);
    property RequestId: String read FRequestId;
    property Statements: TSqlMonitorStatementExecutionList read FStatements;
  end;

  TSqlMonitorClient = class(TObject)
  private
    FOwner: TComponent;
    function BuildRequestPayload(Connection: TDBConnection; StatementSql: TStrings): String;
    function ParseBatchResponse(const JsonText: String): TSqlMonitorBatchResponse;
    function SendJsonRequest(const URL, Method, Payload: String; out ResponseText: String): Integer;
  public
    constructor Create(AOwner: TComponent);
    class function ApprovalTimeoutMs: Cardinal; static;
    class function BaseUrl: String; static;
    class function IsConfigured: Boolean; static;
    class function PollIntervalMs: Cardinal; static;
    class function SupportsConnection(Connection: TDBConnection): Boolean; static;
    class function TryGetSettingInt(const Name: String; DefaultValue: Integer): Integer; static;
    function CancelRequest(const RequestId: String): Boolean;
    function CompleteRequest(Connection: TDBConnection; Context: TSqlMonitorExecutionContext; TotalDurationMs: Cardinal): Boolean;
    function CreateRequest(Connection: TDBConnection; StatementSql: TStrings): TSqlMonitorBatchResponse;
    function GetRequestStatus(const RequestId: String): TSqlMonitorBatchResponse;
    function WaitForDecision(const RequestId: String; out Response: TSqlMonitorBatchResponse): Boolean;
  end;

function SqlMonitorShouldHandle(Connection: TDBConnection): Boolean;
function SqlMonitorGetDecisionMessage(Response: TSqlMonitorBatchResponse): String;

implementation

uses
  System.Math, Vcl.Controls, Vcl.StdCtrls,
  apphelpers, gnugettext, Main;

{$I const.inc}

type
  TSqlMonitorWaitState = class(TObject)
  public
    Cancelled: Boolean;
    procedure HandleCancel(Sender: TObject);
  end;

function BatchStatusFromString(const Value: String): TSqlMonitorBatchStatus;
begin
  if SameText(Value, 'logged') then
    Result := smbsLogged
  else if SameText(Value, 'pending') then
    Result := smbsPending
  else if SameText(Value, 'approved') then
    Result := smbsApproved
  else if SameText(Value, 'rejected') then
    Result := smbsRejected
  else if SameText(Value, 'cancelled') then
    Result := smbsCancelled
  else if SameText(Value, 'error') then
    Result := smbsError
  else
    Result := smbsUnknown;
end;


function GetClientHostName: String;
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


function GetClientActorId: String;
var
  UserBufferSize: DWORD;
  UserName, HostName: String;
begin
  UserBufferSize := 512;
  SetLength(UserName, UserBufferSize);
  if GetUserName(PChar(UserName), UserBufferSize) then
    SetLength(UserName, UserBufferSize-1)
  else
    UserName := '';
  HostName := GetClientHostName;
  Result := UserName;
  if (not HostName.IsEmpty) and (not UserName.IsEmpty) then
    Result := UserName + '@' + HostName
  else if Result.IsEmpty then
    Result := HostName;
end;


function GetClientVersion: String;
begin
  if Assigned(MainForm) then
    Result := MainForm.AppVersion
  else
    Result := '';
end;


function GetConnectionTargetPort(Connection: TDBConnection): Integer;
begin
  Result := 0;
  if not Assigned(Connection) then
    Exit;
  Result := Connection.Parameters.Port;
  if Result <= 0 then
    Result := Connection.Parameters.DefaultPort;
end;


function GetConfiguredSetting(SettingIndex: TAppSettingIndex; const EnvName: String): String;
begin
  Result := '';
  if Assigned(AppSettings) then
    Result := Trim(AppSettings.ReadString(SettingIndex));
  if Result.IsEmpty then
    Result := Trim(GetEnvironmentVariable(EnvName));
end;


function GetSqlMonitorApiKey: String;
begin
  Result := GetConfiguredSetting(asSqlMonitorApiKey, 'HEIDISQL_SQLMONITOR_API_KEY');
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


function GetJsonInt(Obj: TJSONObject; const Name: String; DefaultValue: Int64=-1): Int64;
var
  Value: TJSONValue;
begin
  Result := DefaultValue;
  if Obj = nil then
    Exit;
  Value := Obj.GetValue(Name);
  if Value <> nil then
    Result := StrToInt64Def(Value.Value, DefaultValue);
end;


function GetJsonString(Obj: TJSONObject; const Name: String; const DefaultValue: String=''): String;
var
  Value: TJSONValue;
begin
  Result := DefaultValue;
  if Obj = nil then
    Exit;
  Value := Obj.GetValue(Name);
  if Value <> nil then
    Result := Value.Value;
end;


function NormalizeUrl(const Value: String): String;
begin
  Result := Trim(Value);
  while Result.EndsWith('/') do
    Result := Result.Substring(0, Result.Length-1);
end;


function StatementDecisionFromString(const Value: String): TSqlMonitorStatementDecision;
begin
  if SameText(Value, 'logged') then
    Result := smsdLogged
  else if SameText(Value, 'pending') then
    Result := smsdPending
  else if SameText(Value, 'approved') then
    Result := smsdApproved
  else if SameText(Value, 'rejected') then
    Result := smsdRejected
  else if SameText(Value, 'cancelled') then
    Result := smsdCancelled
  else
    Result := smsdUnknown;
end;


function StatementKindFromString(const Value: String): TSqlMonitorStatementKind;
begin
  if SameText(Value, 'select') then
    Result := smskSelect
  else if SameText(Value, 'insert') then
    Result := smskInsert
  else if SameText(Value, 'update') then
    Result := smskUpdate
  else if SameText(Value, 'delete') then
    Result := smskDelete
  else if SameText(Value, 'other') then
    Result := smskOther
  else
    Result := smskUnknown;
end;


function ParseApiErrorMessage(const ResponseText: String): String;
var
  RootValue: TJSONValue;
  RootObject: TJSONObject;
begin
  Result := ResponseText.Trim;
  if Result.IsEmpty then
    Exit;

  RootValue := TJSONObject.ParseJSONValue(Result);
  if not (RootValue is TJSONObject) then begin
    RootValue.Free;
    Exit;
  end;

  RootObject := RootValue as TJSONObject;
  try
    Result := GetJsonString(RootObject, 'error');
    if Result.IsEmpty then
      Result := GetJsonString(RootObject, 'message');
    if Result.IsEmpty then
      Result := ResponseText.Trim;
  finally
    RootValue.Free;
  end;
end;


function SqlMonitorGetDecisionMessage(Response: TSqlMonitorBatchResponse): String;
begin
  if Response = nil then
    Result := ''
  else
    Result := Response.DecisionReason;
end;


function SqlMonitorShouldHandle(Connection: TDBConnection): Boolean;
begin
  Result := TSqlMonitorClient.SupportsConnection(Connection);
end;


{ TSqlMonitorBatchResponse }

constructor TSqlMonitorBatchResponse.Create;
begin
  inherited Create;
  Status := smbsUnknown;
  FStatements := TSqlMonitorStatementInfoList.Create(True);
end;


destructor TSqlMonitorBatchResponse.Destroy;
begin
  FStatements.Free;
  inherited;
end;


function TSqlMonitorBatchResponse.DecisionReason: String;
var
  Statement: TSqlMonitorStatementInfo;
begin
  Result := ErrorMessage;
  if not Result.IsEmpty then
    Exit;

  for Statement in Statements do begin
    if not Statement.Reason.IsEmpty then begin
      Result := Statement.Reason;
      Exit;
    end;
  end;
end;


function TSqlMonitorBatchResponse.HasGuardedWrites: Boolean;
var
  Statement: TSqlMonitorStatementInfo;
begin
  Result := False;
  for Statement in Statements do begin
    if Statement.Kind in [smskUpdate, smskDelete] then begin
      Result := True;
      Break;
    end;
  end;
end;


{ TSqlMonitorStatementExecution }

constructor TSqlMonitorStatementExecution.Create(AStatementIndex: Integer; const ASQL: String);
begin
  inherited Create;
  StatementIndex := AStatementIndex;
  SQL := ASQL;
  Executed := False;
  Success := False;
  DurationMs := 0;
  RowsAffected := 0;
  RowsFound := 0;
  ErrorMessage := '';
end;


{ TSqlMonitorExecutionContext }

constructor TSqlMonitorExecutionContext.Create(const ARequestId: String; StatementSql: TStrings);
var
  i: Integer;
begin
  inherited Create;
  FRequestId := ARequestId;
  FStatements := TSqlMonitorStatementExecutionList.Create(True);
  if StatementSql <> nil then begin
    for i:=0 to StatementSql.Count-1 do
      FStatements.Add(TSqlMonitorStatementExecution.Create(i, StatementSql[i]));
  end;
end;


destructor TSqlMonitorExecutionContext.Destroy;
begin
  FStatements.Free;
  inherited;
end;


procedure TSqlMonitorExecutionContext.MarkStatementResult(StatementIndex: Integer; Success: Boolean;
  DurationMs: Cardinal; RowsAffected, RowsFound: Int64; const ErrorMessage: String);
var
  Statement: TSqlMonitorStatementExecution;
begin
  for Statement in FStatements do begin
    if Statement.StatementIndex = StatementIndex then begin
      Statement.Executed := True;
      Statement.Success := Success;
      Statement.DurationMs := DurationMs;
      Statement.RowsAffected := RowsAffected;
      Statement.RowsFound := RowsFound;
      Statement.ErrorMessage := ErrorMessage;
      Break;
    end;
  end;
end;


procedure TSqlMonitorExecutionContext.SendCompletion(Connection: TDBConnection; TotalDurationMs: Cardinal);
var
  Client: TSqlMonitorClient;
begin
  if FRequestId.IsEmpty then
    Exit;

  Client := TSqlMonitorClient.Create(MainForm);
  try
    Client.CompleteRequest(Connection, Self, TotalDurationMs);
  finally
    Client.Free;
  end;
end;


{ TSqlMonitorClient }

constructor TSqlMonitorClient.Create(AOwner: TComponent);
begin
  inherited Create;
  FOwner := AOwner;
end;


class function TSqlMonitorClient.ApprovalTimeoutMs: Cardinal;
begin
  Result := TryGetSettingInt('HEIDISQL_SQLMONITOR_TIMEOUT_SECONDS', 120) * 1000;
end;


class function TSqlMonitorClient.BaseUrl: String;
begin
  Result := NormalizeUrl(GetConfiguredSetting(asSqlMonitorUrl, 'HEIDISQL_SQLMONITOR_URL'));
end;


class function TSqlMonitorClient.IsConfigured: Boolean;
begin
  Result := (not BaseUrl.IsEmpty) and (not GetSqlMonitorApiKey.IsEmpty);
end;


class function TSqlMonitorClient.PollIntervalMs: Cardinal;
begin
  Result := TryGetSettingInt('HEIDISQL_SQLMONITOR_POLL_SECONDS', 2) * 1000;
end;


class function TSqlMonitorClient.SupportsConnection(Connection: TDBConnection): Boolean;
begin
  Result := IsConfigured and Assigned(Connection) and Connection.Parameters.IsAnyMySQL;
end;


class function TSqlMonitorClient.TryGetSettingInt(const Name: String; DefaultValue: Integer): Integer;
begin
  Result := StrToIntDef(GetEnvironmentVariable(Name), DefaultValue);
end;


function TSqlMonitorClient.BuildRequestPayload(Connection: TDBConnection; StatementSql: TStrings): String;
var
  RootJson, TargetJson, StatementJson: TJSONObject;
  StatementsJson: TJSONArray;
  i: Integer;
begin
  RootJson := TJSONObject.Create;
  try
    RootJson.AddPair('client_app', APPNAME);
    RootJson.AddPair('client_version', GetClientVersion);
    RootJson.AddPair('actor_id', GetClientActorId);
    RootJson.AddPair('client_host', GetClientHostName);

    TargetJson := TJSONObject.Create;
    TargetJson.AddPair('host', Connection.Parameters.Hostname);
    TargetJson.AddPair('port', TJSONNumber.Create(GetConnectionTargetPort(Connection)));
    TargetJson.AddPair('database', Connection.Database);
    TargetJson.AddPair('db_user', Connection.Parameters.Username);
    RootJson.AddPair('target', TargetJson);

    StatementsJson := TJSONArray.Create;
    if StatementSql <> nil then begin
      for i:=0 to StatementSql.Count-1 do begin
        StatementJson := TJSONObject.Create;
        StatementJson.AddPair('index', TJSONNumber.Create(i));
        StatementJson.AddPair('sql', StatementSql[i]);
        StatementsJson.AddElement(StatementJson);
      end;
    end;
    RootJson.AddPair('statements', StatementsJson);
    Result := RootJson.ToJSON;
  finally
    RootJson.Free;
  end;
end;


function TSqlMonitorClient.CancelRequest(const RequestId: String): Boolean;
var
  ResponseText: String;
  StatusCode: Integer;
begin
  StatusCode := SendJsonRequest(BaseUrl + '/v1/sql-requests/' + EncodeURLParam(RequestId) + '/cancel', 'POST', '{}', ResponseText);
  Result := StatusCode in [200, 202, 204];
end;


function TSqlMonitorClient.CompleteRequest(Connection: TDBConnection; Context: TSqlMonitorExecutionContext;
  TotalDurationMs: Cardinal): Boolean;
var
  ResponseText, Payload: String;
  RootJson, StatementJson: TJSONObject;
  StatementsJson: TJSONArray;
  Statement: TSqlMonitorStatementExecution;
  Retries: Integer;
begin
  Result := False;
  if (Context = nil) or Context.RequestId.IsEmpty then
    Exit;

  RootJson := TJSONObject.Create;
  try
    RootJson.AddPair('client_app', APPNAME);
    RootJson.AddPair('client_version', GetClientVersion);
    RootJson.AddPair('actor_id', GetClientActorId);
    RootJson.AddPair('client_host', GetClientHostName);
    RootJson.AddPair('total_duration_ms', TJSONNumber.Create(TotalDurationMs));

    StatementsJson := TJSONArray.Create;
    for Statement in Context.Statements do begin
      StatementJson := TJSONObject.Create;
      StatementJson.AddPair('index', TJSONNumber.Create(Statement.StatementIndex));
      StatementJson.AddPair('executed', TJSONBool.Create(Statement.Executed));
      StatementJson.AddPair('success', TJSONBool.Create(Statement.Success));
      StatementJson.AddPair('duration_ms', TJSONNumber.Create(Statement.DurationMs));
      StatementJson.AddPair('rows_affected', TJSONNumber.Create(Statement.RowsAffected));
      StatementJson.AddPair('rows_found', TJSONNumber.Create(Statement.RowsFound));
      StatementJson.AddPair('error_message', Statement.ErrorMessage);
      StatementsJson.AddElement(StatementJson);
    end;
    RootJson.AddPair('statements', StatementsJson);
    Payload := RootJson.ToJSON;
  finally
    RootJson.Free;
  end;

  for Retries := 1 to 3 do begin
    try
      SendJsonRequest(BaseUrl + '/v1/sql-requests/' + EncodeURLParam(Context.RequestId) + '/complete', 'POST', Payload, ResponseText);
      Result := True;
      Break;
    except
      on E:Exception do begin
        if Retries = 3 then
          raise ESqlMonitorError.Create(_('SQL monitor completion callback failed: ') + E.Message);
        Sleep(250 * Retries);
      end;
    end;
  end;
end;


function TSqlMonitorClient.CreateRequest(Connection: TDBConnection; StatementSql: TStrings): TSqlMonitorBatchResponse;
var
  ResponseText: String;
begin
  SendJsonRequest(BaseUrl + '/v1/sql-requests', 'POST', BuildRequestPayload(Connection, StatementSql), ResponseText);
  Result := ParseBatchResponse(ResponseText);
end;


function TSqlMonitorClient.GetRequestStatus(const RequestId: String): TSqlMonitorBatchResponse;
var
  ResponseText: String;
begin
  SendJsonRequest(BaseUrl + '/v1/sql-requests/' + EncodeURLParam(RequestId), 'GET', '', ResponseText);
  Result := ParseBatchResponse(ResponseText);
end;


function TSqlMonitorClient.ParseBatchResponse(const JsonText: String): TSqlMonitorBatchResponse;
var
  RootValue, StatementsValue, ItemValue: TJSONValue;
  RootObject, StatementObject: TJSONObject;
  StatementInfo: TSqlMonitorStatementInfo;
begin
  Result := TSqlMonitorBatchResponse.Create;
  if JsonText.Trim.IsEmpty then
    Exit;

  RootValue := TJSONObject.ParseJSONValue(JsonText);
  if not (RootValue is TJSONObject) then begin
    RootValue.Free;
    raise ESqlMonitorError.Create(_('SQL monitor returned an invalid JSON payload.'));
  end;

  RootObject := RootValue as TJSONObject;
  try
    Result.RequestId := GetJsonString(RootObject, 'request_id');
    Result.Status := BatchStatusFromString(GetJsonString(RootObject, 'status'));
    Result.RequiresPolling := GetJsonBool(RootObject, 'requires_polling');
    Result.ErrorMessage := GetJsonString(RootObject, 'error');
    if Result.ErrorMessage.IsEmpty then
      Result.ErrorMessage := GetJsonString(RootObject, 'message');

    StatementsValue := RootObject.GetValue('statements');
    if StatementsValue is TJSONArray then begin
      for ItemValue in TJSONArray(StatementsValue) do begin
        if not (ItemValue is TJSONObject) then
          Continue;
        StatementObject := ItemValue as TJSONObject;
        StatementInfo := TSqlMonitorStatementInfo.Create;
        StatementInfo.Index := GetJsonInt(StatementObject, 'index', 0);
        StatementInfo.SQL := GetJsonString(StatementObject, 'sql');
        StatementInfo.Kind := StatementKindFromString(GetJsonString(StatementObject, 'kind'));
        StatementInfo.Decision := StatementDecisionFromString(GetJsonString(StatementObject, 'decision'));
        StatementInfo.Reason := GetJsonString(StatementObject, 'reason');
        StatementInfo.EstimatedRows := GetJsonInt(StatementObject, 'estimated_rows', -1);
        Result.Statements.Add(StatementInfo);
      end;
    end;
  finally
    RootValue.Free;
  end;
end;


function TSqlMonitorClient.SendJsonRequest(const URL, Method, Payload: String; out ResponseText: String): Integer;
var
  Http: THttpDownload;
  StatusText: String;
begin
  Http := THttpDownload.Create(FOwner);
  try
    Http.URL := URL;
    Http.Method := Method;
    Http.TimeOut := Max(10, ApprovalTimeoutMs div 1000);
    Http.RequestHeaders.Values['Content-Type'] := 'application/json; charset=utf-8';
    Http.RequestHeaders.Values['Accept'] := 'application/json';
    Http.RequestHeaders.Values['X-API-Key'] := GetSqlMonitorApiKey;
    if not SameText(Method, 'GET') then
      Http.RequestBody := Payload;
    Http.SendRequest('');
    ResponseText := Http.LastContent;
    Result := Http.StatusCode;
    if (Result < 200) or (Result > 299) then begin
      StatusText := ParseApiErrorMessage(ResponseText);
      if StatusText.IsEmpty then
        StatusText := f_('HTTP status %d', [Result]);
      raise ESqlMonitorError.Create(StatusText);
    end;
  finally
    Http.Free;
  end;
end;


function TSqlMonitorClient.WaitForDecision(const RequestId: String; out Response: TSqlMonitorBatchResponse): Boolean;
var
  Dialog: TForm;
  StatusLabel, HintLabel: TLabel;
  CancelButton: TButton;
  WaitState: TSqlMonitorWaitState;
  StartTick, NextPoll, ElapsedSeconds: Cardinal;
  LastError: String;
  OwnerWasEnabled: Boolean;
begin
  Response := nil;
  Result := False;
  WaitState := TSqlMonitorWaitState.Create;
  OwnerWasEnabled := False;
  Dialog := TForm.CreateNew(MainForm);
  try
    Dialog.Caption := _('Waiting for SQL approval');
    Dialog.BorderStyle := bsDialog;
    Dialog.Position := poMainFormCenter;
    Dialog.Width := 430;
    Dialog.Height := 165;
    Dialog.BorderIcons := [];

    StatusLabel := TLabel.Create(Dialog);
    StatusLabel.Parent := Dialog;
    StatusLabel.Left := 16;
    StatusLabel.Top := 16;
    StatusLabel.Width := Dialog.ClientWidth - 32;
    StatusLabel.WordWrap := True;
    StatusLabel.Caption := _('Submitting SQL approval request ...');

    HintLabel := TLabel.Create(Dialog);
    HintLabel.Parent := Dialog;
    HintLabel.Left := 16;
    HintLabel.Top := 72;
    HintLabel.Width := Dialog.ClientWidth - 32;
    HintLabel.WordWrap := True;
    HintLabel.Caption := _('The SQL statement will only run after centralized approval succeeds.');

    CancelButton := TButton.Create(Dialog);
    CancelButton.Parent := Dialog;
    CancelButton.Left := Dialog.ClientWidth - 110;
    CancelButton.Top := Dialog.ClientHeight - 45;
    CancelButton.Width := 90;
    CancelButton.Caption := _('Cancel');
    CancelButton.OnClick := WaitState.HandleCancel;

    OwnerWasEnabled := Assigned(MainForm) and MainForm.Enabled;
    if OwnerWasEnabled then
      EnableWindow(MainForm.Handle, False);
    Dialog.Show;
    Dialog.Update;

    StartTick := GetTickCount;
    NextPoll := 0;
    while not WaitState.Cancelled do begin
      Application.ProcessMessages;
      if GetTickCount - StartTick >= ApprovalTimeoutMs then begin
        Response := TSqlMonitorBatchResponse.Create;
        Response.RequestId := RequestId;
        Response.Status := smbsError;
        Response.ErrorMessage := _('Central SQL approval timed out.');
        Break;
      end;

      if GetTickCount >= NextPoll then begin
        FreeAndNil(Response);
        try
          Response := GetRequestStatus(RequestId);
          LastError := '';
          if Response.Status in [smbsApproved, smbsRejected, smbsCancelled, smbsError] then
            Break;
        except
          on E:Exception do begin
            LastError := E.Message;
            FreeAndNil(Response);
          end;
        end;
        NextPoll := GetTickCount + PollIntervalMs;
      end;

      ElapsedSeconds := (GetTickCount - StartTick) div 1000;
      StatusLabel.Caption := f_('Waiting for centralized SQL approval ... (%d s)', [ElapsedSeconds]);
      if LastError.IsEmpty then
        HintLabel.Caption := _('The SQL statement will only run after centralized approval succeeds.')
      else
        HintLabel.Caption := _('Last polling error: ') + LastError;
      Sleep(100);
    end;

    if WaitState.Cancelled then begin
      try
        CancelRequest(RequestId);
      except
        on E:Exception do begin
          if Assigned(MainForm) then
            MainForm.LogSQL(_('SQL monitor cancel warning: ') + E.Message, lcError);
        end;
      end;
      FreeAndNil(Response);
      Response := TSqlMonitorBatchResponse.Create;
      Response.RequestId := RequestId;
      Response.Status := smbsCancelled;
      Response.ErrorMessage := _('Central SQL approval was cancelled by the user.');
    end;
  finally
    if Assigned(MainForm) and OwnerWasEnabled then
      EnableWindow(MainForm.Handle, True);
    Dialog.Free;
    WaitState.Free;
  end;

  Result := Assigned(Response) and (Response.Status = smbsApproved);
end;


{ TSqlMonitorWaitState }

procedure TSqlMonitorWaitState.HandleCancel(Sender: TObject);
begin
  Cancelled := True;
end;

end.
