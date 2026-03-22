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
    function BuildSessionPayload(Connection: TDBConnection; const DatabaseName: String): String;
    function BuildTargetJson(Connection: TDBConnection; const DatabaseName: String): TJSONObject;
    function BuildExecutionPayload(Connection: TDBConnection; const SQL: String; DurationMs: Cardinal; RowsAffected, RowsFound: Int64; Success: Boolean; const ErrorMessage: String): String;
    function BuildRequestPayload(Connection: TDBConnection; StatementSql: TStrings): String;
    function ParseBatchResponse(const JsonText: String): TSqlMonitorBatchResponse;
    function SendJsonRequest(const URL, Method, Payload: String; out ResponseText: String;
      TimeOutSeconds: Cardinal=0): Integer;
  public
    constructor Create(AOwner: TComponent);
    class function ApprovalTimeoutMs: Cardinal; static;
    class function BaseUrl: String; static;
    class function IsConfigured: Boolean; static;
    class function PollIntervalMs: Cardinal; static;
    class function SessionTimeoutSeconds: Cardinal; static;
    class function SupportsConnection(Connection: TDBConnection): Boolean; static;
    class function TryGetSettingInt(const Name: String; DefaultValue: Integer): Integer; static;
    function CancelRequest(const RequestId: String): Boolean;
    function CompleteRequest(Connection: TDBConnection; Context: TSqlMonitorExecutionContext; TotalDurationMs: Cardinal): Boolean;
    function CreateRequest(Connection: TDBConnection; StatementSql: TStrings): TSqlMonitorBatchResponse;
    function GetRequestStatus(const RequestId: String): TSqlMonitorBatchResponse;
    function RegisterSession(Connection: TDBConnection; const DatabaseName: String): Boolean;
    function WaitForDecision(const RequestId: String; out Response: TSqlMonitorBatchResponse): Boolean;
  end;

function SqlMonitorShouldHandle(Connection: TDBConnection): Boolean;
function SqlMonitorGetDecisionMessage(Response: TSqlMonitorBatchResponse): String;
function SqlMonitorTranslate(const MsgId: String): String;
procedure SqlMonitorLogExecutedStatement(Connection: TDBConnection; const SQL: String; DurationMs: Cardinal; RowsAffected, RowsFound: Int64);
procedure SqlMonitorRegisterSession(Connection: TDBConnection; const DatabaseName: String='');
procedure SqlMonitorForgetConnection(Connection: TDBConnection);
procedure SqlMonitorShowError(const Title, Msg: String);

implementation

uses
  System.Math, Vcl.Controls, Vcl.StdCtrls, Vcl.Dialogs,
  apphelpers, gnugettext, Main;

{$I const.inc}

type
  TSqlMonitorWaitState = class(TObject)
  public
    Cancelled: Boolean;
    procedure HandleCancel(Sender: TObject);
  end;

var
  SessionRegistrations: TDictionary<NativeUInt, String>;
  SessionRegistrationsLock: TObject;

function SqlMonitorTranslate(const MsgId: String): String;
var
  LangCode: String;
begin
  Result := _(MsgId);
  if Result <> MsgId then
    Exit;

  LangCode := LowerCase(GetCurrentLanguageCode);
  if (LangCode <> 'pt') and (LangCode <> 'pt_br') then
    Exit;

  if SameText(MsgId, 'Central SQL monitor') then
    Result := 'Monitor SQL centralizado'
  else if SameText(MsgId, 'SQL monitor completion callback failed: ') then
    Result := 'Falha no callback de conclusao do monitor SQL: '
  else if SameText(MsgId, 'SQL monitor returned an invalid JSON payload.') then
    Result := 'O monitor SQL retornou um JSON invalido.'
  else if SameText(MsgId, 'Waiting for SQL approval') then
    Result := 'Aguardando aprovacao SQL'
  else if SameText(MsgId, 'Submitting SQL approval request ...') then
    Result := 'Enviando solicitacao de aprovacao SQL ...'
  else if SameText(MsgId, 'The SQL statement will only run after centralized approval succeeds.') then
    Result := 'A instrucao SQL so sera executada apos a aprovacao centralizada.'
  else if SameText(MsgId, 'Central SQL approval timed out.') then
    Result := 'A aprovacao SQL centralizada excedeu o tempo limite.'
  else if SameText(MsgId, 'Waiting for centralized SQL approval ...') then
    Result := 'Aguardando aprovacao SQL centralizada ...'
  else if SameText(MsgId, 'Waiting for centralized SQL approval ... (%d s)') then
    Result := 'Aguardando aprovacao SQL centralizada ... (%d s)'
  else if SameText(MsgId, 'Last polling error: ') then
    Result := 'Ultimo erro de consulta: '
  else if SameText(MsgId, 'SQL monitor cancel warning: ') then
    Result := 'Aviso ao cancelar no monitor SQL: '
  else if SameText(MsgId, 'Central SQL approval was cancelled by the user.') then
    Result := 'A aprovacao SQL centralizada foi cancelada pelo usuario.'
  else if SameText(MsgId, 'Central SQL approval request returned no request id.') then
    Result := 'A solicitacao de aprovacao SQL centralizada nao retornou request id.'
  else if SameText(MsgId, 'Central SQL approval rejected this batch.') then
    Result := 'A aprovacao SQL centralizada rejeitou este lote.'
  else if SameText(MsgId, 'SQL monitor blocked execution: ') then
    Result := 'Monitor SQL bloqueou a execucao: '
  else if SameText(MsgId, 'Central SQL approval blocked execution') then
    Result := 'Aprovacao SQL centralizada bloqueou a execucao'
  else if SameText(MsgId, 'Central SQL logging is unavailable. Continuing without centralized logging.') then
    Result := 'O log SQL centralizado esta indisponivel. Continuando sem log centralizado.'
  else if SameText(MsgId, 'SQL monitor logging warning: ') then
    Result := 'Aviso de log do monitor SQL: '
  else if SameText(MsgId, 'SQL monitor approval failed: ') then
    Result := 'Falha na aprovacao do monitor SQL: '
  else if SameText(MsgId, 'Central SQL approval failed') then
    Result := 'Falha na aprovacao SQL centralizada';
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


function ResolveTargetDatabase(Connection: TDBConnection; const DatabaseName: String): String;
var
  Databases: TStringList;
begin
  Result := Trim(DatabaseName);
  if Result.IsEmpty and Assigned(Connection) then
    Result := Trim(Connection.Database);
  if Result.IsEmpty and Assigned(Connection) then begin
    Databases := Connection.Parameters.AllDatabasesList;
    try
      if Databases.Count = 1 then
        Result := Trim(Databases[0]);
    finally
      Databases.Free;
    end;
  end;
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


procedure ReleaseSessionRegistration(ConnectionKey: NativeUInt; const DatabaseName: String);
var
  RegisteredDatabase: String;
begin
  System.TMonitor.Enter(SessionRegistrationsLock);
  try
    if SessionRegistrations.TryGetValue(ConnectionKey, RegisteredDatabase)
      and SameText(RegisteredDatabase, DatabaseName) then
      SessionRegistrations.Remove(ConnectionKey);
  finally
    System.TMonitor.Exit(SessionRegistrationsLock);
  end;
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


procedure SqlMonitorForgetConnection(Connection: TDBConnection);
begin
  if Connection = nil then
    Exit;
  System.TMonitor.Enter(SessionRegistrationsLock);
  try
    SessionRegistrations.Remove(NativeUInt(Connection));
  finally
    System.TMonitor.Exit(SessionRegistrationsLock);
  end;
end;


procedure SqlMonitorShowError(const Title, Msg: String);
var
  Dialog: TForm;
  MessageMemo: TMemo;
  OkButton: TButton;
  CaptionText: String;
begin
  if Msg.Trim.IsEmpty then begin
    ErrorDialog(Title, Msg);
    Exit;
  end;

  CaptionText := Title;
  if CaptionText.IsEmpty then
    CaptionText := SqlMonitorTranslate('Central SQL monitor');

  Dialog := TForm.CreateNew(MainForm);
  try
    Dialog.Caption := CaptionText;
    Dialog.BorderStyle := bsSizeable;
    Dialog.Position := poMainFormCenter;
    Dialog.Width := 760;
    Dialog.Height := 420;
    Dialog.Constraints.MinWidth := 540;
    Dialog.Constraints.MinHeight := 280;
    Dialog.BorderIcons := [biSystemMenu, biMaximize];

    MessageMemo := TMemo.Create(Dialog);
    MessageMemo.Parent := Dialog;
    MessageMemo.Left := 16;
    MessageMemo.Top := 16;
    MessageMemo.Width := Dialog.ClientWidth - 32;
    MessageMemo.Height := Dialog.ClientHeight - 78;
    MessageMemo.Anchors := [akLeft, akTop, akRight, akBottom];
    MessageMemo.ReadOnly := True;
    MessageMemo.ScrollBars := ssVertical;
    MessageMemo.WordWrap := True;
    MessageMemo.WantReturns := False;
    MessageMemo.Lines.Text := Msg;

    OkButton := TButton.Create(Dialog);
    OkButton.Parent := Dialog;
    OkButton.Width := 90;
    OkButton.Height := 30;
    OkButton.Left := Dialog.ClientWidth - OkButton.Width - 16;
    OkButton.Top := Dialog.ClientHeight - OkButton.Height - 12;
    OkButton.Anchors := [akRight, akBottom];
    OkButton.Caption := _('OK');
    OkButton.Default := True;
    OkButton.Cancel := True;
    OkButton.ModalResult := mrOk;

    Dialog.ActiveControl := MessageMemo;
    Dialog.ShowModal;
  finally
    Dialog.Free;
  end;
end;


procedure SqlMonitorLogExecutedStatement(Connection: TDBConnection; const SQL: String; DurationMs: Cardinal; RowsAffected, RowsFound: Int64);
var
  Client: TSqlMonitorClient;
  Payload, Url: String;
  TimeoutSeconds: Cardinal;
begin
  if not TSqlMonitorClient.SupportsConnection(Connection) then
    Exit;
  if SQL.Trim.IsEmpty then
    Exit;

  Client := TSqlMonitorClient.Create(nil);
  try
    Url := TSqlMonitorClient.BaseUrl + '/v1/sql-executions';
    TimeoutSeconds := TSqlMonitorClient.SessionTimeoutSeconds;
    Payload := Client.BuildExecutionPayload(Connection, SQL, DurationMs, RowsAffected, RowsFound, True, '');
  finally
    Client.Free;
  end;

  TThread.CreateAnonymousThread(
    procedure
    var
      BackgroundClient: TSqlMonitorClient;
      ResponseText: String;
    begin
      BackgroundClient := TSqlMonitorClient.Create(nil);
      try
        try
          BackgroundClient.SendJsonRequest(Url, 'POST', Payload, ResponseText, TimeoutSeconds);
        except
        end;
      finally
        BackgroundClient.Free;
      end;
    end
  ).Start;
end;

procedure SqlMonitorRegisterSession(Connection: TDBConnection; const DatabaseName: String='');
var
  ConnectionKey: NativeUInt;
  EffectiveDatabase, LastDatabase, Payload: String;
  Client: TSqlMonitorClient;
begin
  if not TSqlMonitorClient.SupportsConnection(Connection) then
    Exit;

  EffectiveDatabase := ResolveTargetDatabase(Connection, DatabaseName);
  if EffectiveDatabase.IsEmpty then
    Exit;

  ConnectionKey := NativeUInt(Connection);
  System.TMonitor.Enter(SessionRegistrationsLock);
  try
    if SessionRegistrations.TryGetValue(ConnectionKey, LastDatabase)
      and SameText(LastDatabase, EffectiveDatabase) then
      Exit;
    SessionRegistrations.AddOrSetValue(ConnectionKey, EffectiveDatabase);
  finally
    System.TMonitor.Exit(SessionRegistrationsLock);
  end;

  Client := TSqlMonitorClient.Create(nil);
  try
    Payload := Client.BuildSessionPayload(Connection, EffectiveDatabase);
  finally
    Client.Free;
  end;

  TThread.CreateAnonymousThread(
    procedure
    var
      BackgroundClient: TSqlMonitorClient;
      ResponseText: String;
    begin
      BackgroundClient := TSqlMonitorClient.Create(nil);
      try
        try
          BackgroundClient.SendJsonRequest(TSqlMonitorClient.BaseUrl + '/v1/sessions', 'POST', Payload,
            ResponseText, TSqlMonitorClient.SessionTimeoutSeconds);
        except
          ReleaseSessionRegistration(ConnectionKey, EffectiveDatabase);
        end;
      finally
        BackgroundClient.Free;
      end;
    end
  ).Start;
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


class function TSqlMonitorClient.SessionTimeoutSeconds: Cardinal;
begin
  Result := Max(1, TryGetSettingInt('HEIDISQL_SQLMONITOR_SESSION_TIMEOUT_SECONDS', 5));
end;


class function TSqlMonitorClient.SupportsConnection(Connection: TDBConnection): Boolean;
begin
  Result := IsConfigured and Assigned(Connection) and Connection.Parameters.IsAnyMySQL;
end;


class function TSqlMonitorClient.TryGetSettingInt(const Name: String; DefaultValue: Integer): Integer;
begin
  Result := StrToIntDef(GetEnvironmentVariable(Name), DefaultValue);
end;


function TSqlMonitorClient.BuildTargetJson(Connection: TDBConnection; const DatabaseName: String): TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('host', Connection.Parameters.Hostname);
  Result.AddPair('port', TJSONNumber.Create(GetConnectionTargetPort(Connection)));
  Result.AddPair('database', ResolveTargetDatabase(Connection, DatabaseName));
  Result.AddPair('db_user', Connection.Parameters.Username);
end;


function TSqlMonitorClient.BuildSessionPayload(Connection: TDBConnection; const DatabaseName: String): String;
var
  RootJson: TJSONObject;
begin
  RootJson := TJSONObject.Create;
  try
    RootJson.AddPair('actor_id', GetClientActorId);
    RootJson.AddPair('client_host', GetClientHostName);
    RootJson.AddPair('client_version', GetClientVersion);
    RootJson.AddPair('target', BuildTargetJson(Connection, DatabaseName));
    Result := RootJson.ToJSON;
  finally
    RootJson.Free;
  end;
end;


function TSqlMonitorClient.BuildExecutionPayload(Connection: TDBConnection; const SQL: String; DurationMs: Cardinal; RowsAffected, RowsFound: Int64; Success: Boolean; const ErrorMessage: String): String;
var
  RootJson, StatementJson: TJSONObject;
  StatementsJson: TJSONArray;
begin
  RootJson := TJSONObject.Create;
  try
    RootJson.AddPair('client_app', APPNAME);
    RootJson.AddPair('client_version', GetClientVersion);
    RootJson.AddPair('actor_id', GetClientActorId);
    RootJson.AddPair('client_host', GetClientHostName);
    RootJson.AddPair('target', BuildTargetJson(Connection, ''));
    RootJson.AddPair('total_duration_ms', TJSONNumber.Create(DurationMs));

    StatementsJson := TJSONArray.Create;
    StatementJson := TJSONObject.Create;
    StatementJson.AddPair('index', TJSONNumber.Create(0));
    StatementJson.AddPair('sql', SQL);
    StatementJson.AddPair('executed', TJSONBool.Create(True));
    StatementJson.AddPair('success', TJSONBool.Create(Success));
    StatementJson.AddPair('duration_ms', TJSONNumber.Create(DurationMs));
    StatementJson.AddPair('rows_affected', TJSONNumber.Create(RowsAffected));
    StatementJson.AddPair('rows_found', TJSONNumber.Create(RowsFound));
    StatementJson.AddPair('error_message', ErrorMessage);
    StatementsJson.AddElement(StatementJson);
    RootJson.AddPair('statements', StatementsJson);
    Result := RootJson.ToJSON;
  finally
    RootJson.Free;
  end;
end;


function TSqlMonitorClient.BuildRequestPayload(Connection: TDBConnection; StatementSql: TStrings): String;
var
  RootJson, StatementJson: TJSONObject;
  StatementsJson: TJSONArray;
  i: Integer;
begin
  RootJson := TJSONObject.Create;
  try
    RootJson.AddPair('client_app', APPNAME);
    RootJson.AddPair('client_version', GetClientVersion);
    RootJson.AddPair('actor_id', GetClientActorId);
    RootJson.AddPair('client_host', GetClientHostName);
    RootJson.AddPair('target', BuildTargetJson(Connection, ''));

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
          raise ESqlMonitorError.Create(SqlMonitorTranslate('SQL monitor completion callback failed: ') + E.Message);
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


function TSqlMonitorClient.RegisterSession(Connection: TDBConnection; const DatabaseName: String): Boolean;
var
  ResponseText: String;
  StatusCode: Integer;
begin
  StatusCode := SendJsonRequest(BaseUrl + '/v1/sessions', 'POST', BuildSessionPayload(Connection, DatabaseName),
    ResponseText, SessionTimeoutSeconds);
  Result := StatusCode in [200, 201, 202, 204];
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


function TSqlMonitorClient.SendJsonRequest(const URL, Method, Payload: String; out ResponseText: String;
  TimeOutSeconds: Cardinal=0): Integer;
var
  Http: THttpDownload;
  StatusText: String;
  EffectiveTimeOut: Cardinal;
begin
  Http := THttpDownload.Create(FOwner);
  try
    Http.URL := URL;
    Http.Method := Method;
    if TimeOutSeconds > 0 then
      EffectiveTimeOut := TimeOutSeconds
    else
      EffectiveTimeOut := Max(10, ApprovalTimeoutMs div 1000);
    Http.TimeOut := EffectiveTimeOut;
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
  StatusLabel: TLabel;
  HintMemo: TMemo;
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
    Dialog.Caption := SqlMonitorTranslate('Waiting for SQL approval');
    Dialog.BorderStyle := bsSizeable;
    Dialog.Position := poMainFormCenter;
    Dialog.Width := 620;
    Dialog.Height := 280;
    Dialog.Constraints.MinWidth := 520;
    Dialog.Constraints.MinHeight := 220;
    Dialog.BorderIcons := [biSystemMenu, biMaximize];

    StatusLabel := TLabel.Create(Dialog);
    StatusLabel.Parent := Dialog;
    StatusLabel.Left := 16;
    StatusLabel.Top := 16;
    StatusLabel.Width := Dialog.ClientWidth - 32;
    StatusLabel.WordWrap := True;
    StatusLabel.Caption := SqlMonitorTranslate('Submitting SQL approval request ...');

    HintMemo := TMemo.Create(Dialog);
    HintMemo.Parent := Dialog;
    HintMemo.Left := 16;
    HintMemo.Top := 56;
    HintMemo.Width := Dialog.ClientWidth - 32;
    HintMemo.Height := Dialog.ClientHeight - 112;
    HintMemo.Anchors := [akLeft, akTop, akRight, akBottom];
    HintMemo.ReadOnly := True;
    HintMemo.ScrollBars := ssVertical;
    HintMemo.WordWrap := True;
    HintMemo.TabStop := False;
    HintMemo.Lines.Text := SqlMonitorTranslate('The SQL statement will only run after centralized approval succeeds.');

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
        Response.ErrorMessage := SqlMonitorTranslate('Central SQL approval timed out.');
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
      StatusLabel.Caption := Format(SqlMonitorTranslate('Waiting for centralized SQL approval ... (%d s)'), [ElapsedSeconds]);
      if LastError.IsEmpty then
        HintMemo.Lines.Text := SqlMonitorTranslate('The SQL statement will only run after centralized approval succeeds.')
      else
        HintMemo.Lines.Text := SqlMonitorTranslate('Last polling error: ') + LastError;
      Sleep(100);
    end;

    if WaitState.Cancelled then begin
      try
        CancelRequest(RequestId);
      except
        on E:Exception do begin
          if Assigned(MainForm) then
            MainForm.LogSQL(SqlMonitorTranslate('SQL monitor cancel warning: ') + E.Message, lcError);
        end;
      end;
      FreeAndNil(Response);
      Response := TSqlMonitorBatchResponse.Create;
      Response.RequestId := RequestId;
      Response.Status := smbsCancelled;
      Response.ErrorMessage := SqlMonitorTranslate('Central SQL approval was cancelled by the user.');
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

initialization
  SessionRegistrations := TDictionary<NativeUInt, String>.Create;
  SessionRegistrationsLock := TObject.Create;

finalization
  SessionRegistrations.Free;
  SessionRegistrationsLock.Free;

end.

