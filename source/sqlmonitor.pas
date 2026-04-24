unit sqlmonitor;

interface

uses
  System.Classes, System.SysUtils, System.Generics.Collections, System.JSON,
  Winapi.Windows, Vcl.Forms, dbconnection;

type
  ESqlMonitorError = class(Exception);

  ESqlMonitorHttpError = class(ESqlMonitorError)
  public
    StatusCode: Integer;
    constructor Create(AStatusCode: Integer; const Msg: String);
  end;

  TSqlMonitorBatchStatus = (smbsUnknown, smbsLogged, smbsPending, smbsApproved, smbsRejected, smbsCancelled, smbsError);
  TSqlMonitorStatementKind = (smskUnknown, smskSelect, smskInsert, smskUpdate, smskDelete, smskOther);
  TSqlMonitorStatementDecision = (smsdUnknown, smsdLogged, smsdPending, smsdApproved, smsdRejected, smsdCancelled);
  TSqlMonitorCredentialMode = (smcmBypass, smcmManaged);

  TSqlMonitorCredentialResponse = record
    Mode: TSqlMonitorCredentialMode;
    DbUser: String;
    DbPassword: String;
    Reason: String;
  end;

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
    function BuildAuthLoginPayload(const Username, Password: String): String;
    function BuildCredentialResolvePayload(Connection: TDBConnection): String;
    function BuildSessionPayload(Connection: TDBConnection; const DatabaseName: String): String;
    function BuildTicketLookupPayload(Connection: TDBConnection; const TicketNumber: String): String;
    function BuildTargetJson(Connection: TDBConnection; const DatabaseName: String): TJSONObject;
    function BuildExecutionPayload(Connection: TDBConnection; const SQL, TicketNumber: String; DurationMs: Cardinal; RowsAffected, RowsFound: Int64; Success: Boolean; const ErrorMessage: String): String;
    function BuildRequestPayload(Connection: TDBConnection; StatementSql: TStrings; const TicketNumber: String): String;
    function ParseBatchResponse(const JsonText: String): TSqlMonitorBatchResponse;
    function ParseCredentialResponse(const JsonText: String): TSqlMonitorCredentialResponse;
    function SendJsonRequest(const URL, Method, Payload: String; out ResponseText: String;
      TimeOutSeconds: Cardinal=0): Integer;
  public
    constructor Create(AOwner: TComponent);
    class function ApprovalTimeoutMs: Cardinal; static;
    class function BaseUrl: String; static;
    class function CentralAuthEnabled: Boolean; static;
    class function IsConfigured: Boolean; static;
    class function PollIntervalMs: Cardinal; static;
    class function SessionTimeoutSeconds: Cardinal; static;
    class function SupportsCentralAuthConnection(Connection: TDBConnection): Boolean; static;
    class function SupportsConnection(Connection: TDBConnection): Boolean; static;
    class function SupportsSessionConnection(Connection: TDBConnection): Boolean; static;
    class function TryGetSettingInt(const Name: String; DefaultValue: Integer): Integer; static;
    function CancelRequest(const RequestId: String): Boolean;
    function CompleteRequest(Connection: TDBConnection; Context: TSqlMonitorExecutionContext; TotalDurationMs: Cardinal): Boolean;
    function CreateRequest(Connection: TDBConnection; StatementSql: TStrings; const TicketNumber: String=''): TSqlMonitorBatchResponse;
    function GetRequestStatus(const RequestId: String): TSqlMonitorBatchResponse;
    function LoginCentralAuth(const Username, Password: String; out ActorId, AuthToken: String; out ExpiresAt: TDateTime): Boolean;
    function LookupTicket(Connection: TDBConnection; const TicketNumber: String; out TicketTitle, TicketStatus: String): Boolean;
    function RegisterSession(Connection: TDBConnection; const DatabaseName: String): Boolean;
    function ResolveDbCredentials(Connection: TDBConnection): TSqlMonitorCredentialResponse;
    function WaitForDecision(const RequestId: String; out Response: TSqlMonitorBatchResponse): Boolean;
  end;

function SqlMonitorCentralAuthEnabled: Boolean;
function SqlMonitorShouldHandle(Connection: TDBConnection): Boolean;
function SqlMonitorEnsureStartupAuthentication: Boolean;
function SqlMonitorEnsureCentralAuthSession(const InitialError: String=''): Boolean;
function SqlMonitorHasValidCentralAuthToken: Boolean;
function SqlMonitorGetCurrentAuthToken: String;
function SqlMonitorGetApiKey: String;
procedure SqlMonitorClearCentralAuthSession;
function SqlMonitorGetDecisionMessage(Response: TSqlMonitorBatchResponse): String;
function SqlMonitorTranslate(const MsgId: String): String;

procedure SqlMonitorPrepareConnectionAuthentication(Connection: TDBConnection);
procedure SqlMonitorRefreshConfiguration;
function SqlMonitorPrepareExecution(Connection: TDBConnection; StatementSql: TStrings; out Context: TSqlMonitorExecutionContext): Boolean;
function SqlMonitorPrepareSingleExecution(Connection: TDBConnection; const SQL: String; out Context: TSqlMonitorExecutionContext): Boolean;
procedure SqlMonitorLogExecutedStatement(Connection: TDBConnection; const SQL: String; DurationMs: Cardinal; RowsAffected, RowsFound: Int64; const TicketNumber: String='');
procedure SqlMonitorRegisterSession(Connection: TDBConnection; const DatabaseName: String='');
procedure SqlMonitorForgetConnection(Connection: TDBConnection);
procedure SqlMonitorShowError(const Title, Msg: String);

implementation

uses
  System.Math, System.DateUtils, Vcl.Controls, Vcl.StdCtrls, Vcl.Dialogs, Vcl.Graphics,
  apphelpers, gnugettext, Main;

{$I const.inc}

type
  TSqlMonitorWaitState = class(TObject)
  public
    Cancelled: Boolean;
    procedure HandleCancel(Sender: TObject);
  end;

  TSqlMonitorTicketInfo = record
    Number: String;
    Title: String;
    Status: String;
  end;

  TTicketLookupDialogState = class(TObject)
  private
    FConnection: TDBConnection;
    FTicketEdit: TEdit;
    FInfoLabel: TLabel;
    FLookupButton: TButton;
    FLoadedInfo: TSqlMonitorTicketInfo;
    procedure SetInfoMessage(const Msg: String; Color: TColor);
    function CurrentTicketNumber: String;
  public
    constructor Create(AConnection: TDBConnection; ATicketEdit: TEdit; AInfoLabel: TLabel;
      ALookupButton: TButton; const InitialInfo: TSqlMonitorTicketInfo; InitialInfoAvailable: Boolean);
    procedure TicketEditChange(Sender: TObject);
    procedure LookupButtonClick(Sender: TObject);
    function LoadTicketInfo(ShowErrors: Boolean): Boolean;
    property LoadedInfo: TSqlMonitorTicketInfo read FLoadedInfo;
  end;
  TSqlMonitorCentralAuthDialogState = class(TObject)
  private
    FDialog: TForm;
    FPromptLabel: TLabel;
    FErrorLabel: TLabel;
    FUserLabel: TLabel;
    FUserEdit: TEdit;
    FPasswordLabel: TLabel;
    FPasswordEdit: TEdit;
    FSignInButton: TButton;
    FCancelButton: TButton;
    procedure SetError(const Msg: String);
    procedure UpdateLayout;
  public
    constructor Create(ADialog: TForm; APromptLabel, AErrorLabel, AUserLabel: TLabel;
      AUserEdit: TEdit; APasswordLabel: TLabel; APasswordEdit: TEdit;
      ASignInButton, ACancelButton: TButton; const InitialError: String);
    procedure HandleCloseQuery(Sender: TObject; var CanClose: Boolean);
  end;

var
  SessionRegistrations: TDictionary<NativeUInt, String>;
  SessionRegistrationsLock: TObject;
  SqlMonitorConfigLock: TObject;
  SqlMonitorAuthLock: TObject;
  TicketCacheLock: TObject;
  SqlMonitorConfigInitialized: Boolean;
  CachedSqlMonitorUrl: String;
  CachedSqlMonitorApiKey: String;
  CachedSqlMonitorCentralAuthEnabled: Boolean;
  CachedCentralAuthActorId: String;
  CachedCentralAuthExpiresAt: TDateTime;
  CachedCentralAuthToken: String;
  CachedCentralAuthUsername: String;
  CachedTicketInfo: TDictionary<String, TSqlMonitorTicketInfo>;

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
  else if SameText(MsgId, 'Writes are blocked for Espelho replica databases.') then
    Result := 'Escritas estao bloqueadas para bancos replica Espelho'
  else if SameText(MsgId, 'Central SQL logging is unavailable. Continuing without centralized logging.') then
    Result := 'O log SQL centralizado esta indisponivel. Continuando sem log centralizado.'
  else if SameText(MsgId, 'SQL monitor logging warning: ') then
    Result := 'Aviso de log do monitor SQL: '
  else if SameText(MsgId, 'SQL monitor approval failed: ') then
    Result := 'Falha na aprovacao do monitor SQL: '
  else if SameText(MsgId, 'Central SQL approval failed') then
    Result := 'Falha na aprovacao SQL centralizada'
  else if SameText(MsgId, 'Confirm SQL write') then
    Result := 'Confirmar escrita SQL'
  else if SameText(MsgId, 'Ticket number') then
    Result := 'Numero do chamado'
  else if SameText(MsgId, 'Load ticket title') then
    Result := 'Carregar chamado'
  else if SameText(MsgId, 'Type a ticket number and load the title to confirm it.') then
    Result := 'Informe o numero do chamado e carregue o titulo para confirmar.'
  else if SameText(MsgId, 'Click Load ticket title to confirm this ticket.') then
    Result := 'Clique em Carregar chamado para confirmar este ticket.'
  else if SameText(MsgId, 'Loading ticket title ...') then
    Result := 'Carregando titulo do chamado ...'
  else if SameText(MsgId, 'Ticket lookup failed: ') then
    Result := 'Falha ao consultar chamado: '
  else if SameText(MsgId, 'Ticket %s: %s') then
    Result := 'Chamado %s: %s'
  else if SameText(MsgId, 'Confirm this SQL write before it is executed. You may also inform a ticket number.') then
    Result := 'Confirme esta escrita SQL antes da execucao. Se desejar, informe tambem o numero do chamado.'
  else if SameText(MsgId, 'This write will wait for centralized approval after you confirm the ticket number.') then
    Result := 'Esta escrita aguardara aprovacao centralizada apos a confirmacao do numero do chamado.'
  else if SameText(MsgId, 'This write will be logged centrally after you confirm the ticket number.') then
    Result := 'Esta escrita sera registrada no monitor centralizado apos a confirmacao do numero do chamado.'
  else if SameText(MsgId, 'Execution target') then
    Result := 'Destino da execucao'
  else if SameText(MsgId, 'Production environment') then
    Result := 'AMBIENTE DE PRODUCAO'
  else if SameText(MsgId, 'The following target will receive this SQL write:') then
    Result := 'A escrita SQL sera executada no seguinte destino:'
  else if SameText(MsgId, 'API approval confirmed this production write. Do you want to execute it now?') then
    Result := 'A API confirmou esta escrita em producao. Deseja executar agora?'
  else if SameText(MsgId, 'Confirm production execution') then
    Result := 'Confirmar execucao em producao'
  else if SameText(MsgId, 'Production execution was cancelled by the user after API approval.') then
    Result := 'A execucao em producao foi cancelada pelo usuario apos a aprovacao da API.'
  else if SameText(MsgId, 'Change connection') then
    Result := 'Alterar conexao'
  else if SameText(MsgId, 'You are changing to the following connection:') then
    Result := 'Voce esta mudando para a seguinte conexao:'
  else if SameText(MsgId, 'Do you want to continue?') then
    Result := 'Deseja continuar?'
  else if SameText(MsgId, 'Another HeidiSQL instance is already running. Close the other window before installing the update.') then
    Result := 'Outra instancia do HeidiSQL ja esta em execucao. Feche a outra janela antes de instalar a atualizacao.'
  else if SameText(MsgId, 'HeidiSQL CSLOG update was blocked because another HeidiSQL window is open. This window will be closed now.') then
    Result := 'A atualizacao do HeidiSQL CSLOG foi bloqueada porque existe outra janela do HeidiSQL aberta. Esta janela sera fechada agora.'
  else if SameText(MsgId, 'Confirm') then
    Result := 'Confirmar'
  else if SameText(MsgId, 'Central SQL monitor blocked execution') then
    Result := 'Monitor SQL centralizado bloqueou a execucao'
  else if SameText(MsgId, 'SQL monitor write registration failed: ') then
    Result := 'Falha no registro da escrita no monitor SQL: '
  else if SameText(MsgId, 'Central SQL write registration failed') then
    Result := 'Falha no registro centralizado da escrita SQL'
  else if SameText(MsgId, 'Central SQL write registration failed.') then
    Result := 'Falha no registro centralizado da escrita SQL.'
  else if SameText(MsgId, 'Use centralized AD authentication') then
    Result := 'Usar autenticacao AD centralizada'
  else if SameText(MsgId, 'Centralized AD authentication') then
    Result := 'Autenticacao AD centralizada'
  else if SameText(MsgId, 'Sign in with your Active Directory credentials to continue.') then
    Result := 'Informe suas credenciais do Active Directory para continuar.'
  else if SameText(MsgId, 'User name') then
    Result := 'Usuario'
  else if SameText(MsgId, 'Password') then
    Result := 'Senha'
  else if SameText(MsgId, 'Sign in') then
    Result := 'Entrar'
  else if SameText(MsgId, 'Centralized AD authentication failed') then
    Result := 'Falha na autenticacao AD centralizada'
  else if SameText(MsgId, 'Centralized AD authentication is enabled, but the SQL monitor URL or API key is missing.') then
    Result := 'A autenticacao AD centralizada esta habilitada, mas falta configurar a URL ou a chave da API do monitor SQL.'
  else if SameText(MsgId, 'Centralized AD authentication was cancelled by the user.') then
    Result := 'A autenticacao AD centralizada foi cancelada pelo usuario.'
  else if SameText(MsgId, 'Centralized AD session expired. Sign in again to continue.') then
    Result := 'A sessao AD centralizada expirou. Entre novamente para continuar.'
  else if SameText(MsgId, 'Managed DB credentials were not returned by the central service.') then
    Result := 'A credencial gerenciada do banco nao foi retornada pelo servico central.'
  else if SameText(MsgId, 'Centralized AD login did not return an auth token.') then
    Result := 'A autenticacao AD centralizada nao retornou um token de autenticacao.'
  else if SameText(MsgId, 'Centralized DB credential resolution returned an invalid mode.') then
    Result := 'A resolucao centralizada de credencial do banco retornou um modo invalido.'
  else if SameText(MsgId, 'Refresh sessions from API') then
    Result := 'Atualizar sessoes da API'
  else if SameText(MsgId, 'Session catalog synchronization warning') then
    Result := 'Aviso na sincronizacao do catalogo de sessoes'
  else if SameText(MsgId, 'Session catalog synchronized successfully.') then
    Result := 'Catalogo de sessoes sincronizado com sucesso.'
  else if SameText(MsgId, 'Session catalog synchronized: %d created, %d updated, %d archived.') then
    Result := 'Catalogo de sessoes sincronizado: %d criadas, %d atualizadas, %d arquivadas.'
  else if SameText(MsgId, 'Session catalog synchronization failed: ') then
    Result := 'Falha na sincronizacao do catalogo de sessoes: '
  else if SameText(MsgId, 'Connection catalog synchronization requires centralized AD authentication.') then
    Result := 'A sincronizacao do catalogo de conexoes requer autenticacao AD centralizada.'
  else if SameText(MsgId, 'Connection catalog synchronization requires the SQL monitor URL and API key.') then
    Result := 'A sincronizacao do catalogo de conexoes requer a URL e a chave da API do monitor SQL.'
  else if SameText(MsgId, 'The central service returned an invalid session catalog payload.') then
    Result := 'O servico central retornou um payload invalido para o catalogo de sessoes.'
  else if SameText(MsgId, 'The central service returned an incomplete session catalog entry.') then
    Result := 'O servico central retornou um item incompleto no catalogo de sessoes.'
  else if SameText(MsgId, 'The central service returned an unsupported network type for catalog entry "%s".') then
    Result := 'O servico central retornou um tipo de rede nao suportado para o item "%s" do catalogo.'
  else if SameText(MsgId, 'This CSLOG build manages sessions from the API catalog. Use stock HeidiSQL for custom connections.') then
    Result := 'Esta versao CSLOG gerencia sessoes pelo catalogo da API. Use o HeidiSQL original para conexoes personalizadas.'
  else if SameText(MsgId, 'No managed sessions were loaded yet. Use More > Refresh sessions from API, or check the SQL monitor configuration.') then
    Result := 'Nenhuma sessao gerenciada foi carregada. Use Mais > Atualizar sessoes da API, ou verifique a configuracao do monitor SQL.'
  else if SameText(MsgId, 'Pending grid changes') then
    Result := 'Alteracoes pendentes na grade'
  else if SameText(MsgId, 'There are pending grid changes. Use "Post changes" or "Cancel editing" before continuing.') then
    Result := 'Existem alteracoes pendentes na grade. Use "Post changes" ou "Cancel editing" antes de continuar.'
  else if SameText(MsgId, 'There are pending grid changes. Use "Post changes" or "Cancel editing" before %s.') then
    Result := 'Existem alteracoes pendentes na grade. Use "Post changes" ou "Cancel editing" antes de %s.'
  else if SameText(MsgId, 'executing a new SQL query') then
    Result := 'executar uma nova consulta SQL'
  else if SameText(MsgId, 'Sessions in this build are managed by the CSLOG API catalog. Use stock HeidiSQL for custom connections.') then
    Result := 'As sessoes desta versao sao gerenciadas pelo catalogo da API CSLOG. Use o HeidiSQL original para conexoes personalizadas.'
  else if SameText(MsgId, 'HeidiSQL CSLOG update') then
    Result := 'Atualizacao HeidiSQL CSLOG'
  else if SameText(MsgId, 'Checking for HeidiSQL CSLOG updates...') then
    Result := 'Verificando atualizacoes do HeidiSQL CSLOG...'
  else if SameText(MsgId, 'HeidiSQL CSLOG is up to date.') then
    Result := 'HeidiSQL CSLOG ja esta atualizado.'
  else if SameText(MsgId, 'Downloading HeidiSQL CSLOG update...') then
    Result := 'Baixando atualizacao do HeidiSQL CSLOG...'
  else if SameText(MsgId, 'Preparing HeidiSQL CSLOG update installation...') then
    Result := 'Preparando instalacao da atualizacao do HeidiSQL CSLOG...'
  else if SameText(MsgId, 'The central service returned an invalid update payload.') then
    Result := 'O servico central retornou um payload invalido para atualizacao.'
  else if SameText(MsgId, 'The central service did not return an update download URL.') then
    Result := 'O servico central nao retornou a URL de download da atualizacao.'
  else if SameText(MsgId, 'The downloaded HeidiSQL CSLOG update failed integrity validation.') then
    Result := 'A atualizacao baixada do HeidiSQL CSLOG falhou na validacao de integridade.'
  else if SameText(MsgId, 'No release notes were provided.') then
    Result := 'Nenhuma nota de versao foi informada.'
  else if SameText(MsgId, 'A mandatory HeidiSQL CSLOG update is available.') then
    Result := 'Uma atualizacao obrigatoria do HeidiSQL CSLOG esta disponivel.' + CRLF + CRLF + 'Instalada: %s' + CRLF + 'Disponivel: %s' + CRLF + CRLF + '%s' + CRLF + CRLF + 'A atualizacao sera instalada agora.'
  else if SameText(MsgId, 'A new HeidiSQL CSLOG version is available.') then
    Result := 'Uma nova versao do HeidiSQL CSLOG esta disponivel.' + CRLF + CRLF + 'Instalada: %s' + CRLF + 'Disponivel: %s' + CRLF + CRLF + '%s' + CRLF + CRLF + 'Atualizar agora?'
  else if SameText(MsgId, 'HeidiSQL CSLOG update was downloaded and will be installed now.') then
    Result := 'A atualizacao do HeidiSQL CSLOG foi baixada e sera instalada agora. O aplicativo sera fechado.'
  else if SameText(MsgId, 'Unable to install HeidiSQL CSLOG update: ') then
    Result := 'Nao foi possivel instalar a atualizacao do HeidiSQL CSLOG: ';
  else if SameText(MsgId, 'Choose background colors for API-managed sessions by environment. "None" keeps the session-specific color.') then
    Result := 'Escolha as cores de fundo das sessoes gerenciadas pela API por ambiente. "Nenhuma" mantem a cor especifica da sessao.'
  else if SameText(MsgId, 'Production') then
    Result := 'Producao'
  else if SameText(MsgId, 'Replica (Espelho)') then
    Result := 'Replica (Espelho)'
  else if SameText(MsgId, 'Test (Teste)') then
    Result := 'Teste (Teste)';
end;


constructor ESqlMonitorHttpError.Create(AStatusCode: Integer; const Msg: String);
begin
  inherited Create(Msg);
  StatusCode := AStatusCode;
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


function GetCurrentCentralAuthActorId: String;
begin
  System.TMonitor.Enter(SqlMonitorAuthLock);
  try
    Result := CachedCentralAuthActorId;
  finally
    System.TMonitor.Exit(SqlMonitorAuthLock);
  end;
end;


function GetCurrentCentralAuthToken: String;
begin
  System.TMonitor.Enter(SqlMonitorAuthLock);
  try
    if (CachedCentralAuthToken <> '') and (CachedCentralAuthExpiresAt > 0) and (CachedCentralAuthExpiresAt <= IncSecond(Now, 5)) then
      Result := ''
    else
      Result := CachedCentralAuthToken;
  finally
    System.TMonitor.Exit(SqlMonitorAuthLock);
  end;
end;


function GetCurrentCentralAuthUsername: String;
begin
  System.TMonitor.Enter(SqlMonitorAuthLock);
  try
    Result := CachedCentralAuthUsername;
  finally
    System.TMonitor.Exit(SqlMonitorAuthLock);
  end;
end;


function HasValidCentralAuthToken: Boolean;
begin
  System.TMonitor.Enter(SqlMonitorAuthLock);
  try
    Result := (CachedCentralAuthToken <> '') and ((CachedCentralAuthExpiresAt = 0) or (CachedCentralAuthExpiresAt > IncSecond(Now, 5)));
  finally
    System.TMonitor.Exit(SqlMonitorAuthLock);
  end;
end;



procedure ClearCachedTicketNumbers; forward;
procedure ClearCentralAuthSession;
begin
  System.TMonitor.Enter(SqlMonitorAuthLock);
  try
    CachedCentralAuthActorId := '';
    CachedCentralAuthExpiresAt := 0;
    CachedCentralAuthToken := '';
    CachedCentralAuthUsername := '';
  finally
    System.TMonitor.Exit(SqlMonitorAuthLock);
  end;
  ClearCachedTicketNumbers;
end;


procedure StoreCentralAuthSession(const Username, ActorId, AuthToken: String; ExpiresAt: TDateTime);
begin
  System.TMonitor.Enter(SqlMonitorAuthLock);
  try
    CachedCentralAuthUsername := Trim(Username);
    CachedCentralAuthActorId := Trim(ActorId);
    CachedCentralAuthToken := Trim(AuthToken);
    CachedCentralAuthExpiresAt := ExpiresAt;
  finally
    System.TMonitor.Exit(SqlMonitorAuthLock);
  end;
end;


function TryParseCentralAuthExpiration(const Value: String; out ParsedValue: TDateTime): Boolean;
begin
  Result := False;
  ParsedValue := 0;
  if Trim(Value).IsEmpty then
    Exit;
  try
    ParsedValue := ISO8601ToDate(Value, False);
    Result := True;
  except
    try
      ParsedValue := ISO8601ToDate(Value, True);
      Result := True;
    except
      ParsedValue := 0;
    end;
  end;
end;


function GetClientActorId: String;
var
  UserBufferSize: DWORD;
  UserName, HostName: String;
begin
  Result := GetCurrentCentralAuthActorId;
  if not Result.IsEmpty then
    Exit;

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



procedure CenterFormOnActiveMonitor(AForm: TCustomForm);
var
  Monitor: Vcl.Forms.TMonitor;
  WorkArea: TRect;
begin
  if Assigned(MainForm) and MainForm.HandleAllocated then
    Monitor := Screen.MonitorFromWindow(MainForm.Handle, mdNearest)
  else if Application.Handle <> 0 then
    Monitor := Screen.MonitorFromWindow(Application.Handle, mdNearest)
  else
    Monitor := Screen.PrimaryMonitor;

  if not Assigned(Monitor) then
    Exit;

  WorkArea := Monitor.WorkareaRect;
  AForm.Left := WorkArea.Left + ((WorkArea.Right - WorkArea.Left) - AForm.Width) div 2;
  AForm.Top := WorkArea.Top + ((WorkArea.Bottom - WorkArea.Top) - AForm.Height) div 2;
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


function BuildTicketCacheKey(Connection: TDBConnection): String;
var
  DatabaseName: String;
begin
  Result := '';
  if Connection = nil then
    Exit;
  DatabaseName := LowerCase(ResolveTargetDatabase(Connection, ''));
  Result := LowerCase(Connection.Parameters.Hostname) + '|' + IntToStr(GetConnectionTargetPort(Connection)) + '|' + DatabaseName;
end;


function EmptyTicketInfo: TSqlMonitorTicketInfo;
begin
  Result.Number := '';
  Result.Title := '';
  Result.Status := '';
end;


function GetCachedTicketInfo(Connection: TDBConnection; out TicketInfo: TSqlMonitorTicketInfo): Boolean;
var
  Key: String;
begin
  TicketInfo := EmptyTicketInfo;
  Result := False;
  Key := BuildTicketCacheKey(Connection);
  if Key.IsEmpty then
    Exit;
  System.TMonitor.Enter(TicketCacheLock);
  try
    Result := CachedTicketInfo.TryGetValue(Key, TicketInfo);
  finally
    System.TMonitor.Exit(TicketCacheLock);
  end;
end;


function GetCachedTicketNumber(Connection: TDBConnection): String;
var
  TicketInfo: TSqlMonitorTicketInfo;
begin
  Result := '';
  if GetCachedTicketInfo(Connection, TicketInfo) then
    Result := TicketInfo.Number;
end;


procedure CacheTicketInfo(Connection: TDBConnection; const TicketInfo: TSqlMonitorTicketInfo);
var
  Key: String;
begin
  Key := BuildTicketCacheKey(Connection);
  if Key.IsEmpty then
    Exit;
  System.TMonitor.Enter(TicketCacheLock);
  try
    if TicketInfo.Number.IsEmpty then
      CachedTicketInfo.Remove(Key)
    else
      CachedTicketInfo.AddOrSetValue(Key, TicketInfo);
  finally
    System.TMonitor.Exit(TicketCacheLock);
  end;
end;


procedure CacheTicketNumber(Connection: TDBConnection; const TicketNumber: String);
var
  TicketInfo: TSqlMonitorTicketInfo;
begin
  TicketInfo := EmptyTicketInfo;
  TicketInfo.Number := Trim(TicketNumber);
  CacheTicketInfo(Connection, TicketInfo);
end;


procedure ClearCachedTicketNumbers;
begin
  System.TMonitor.Enter(TicketCacheLock);
  try
    CachedTicketInfo.Clear;
  finally
    System.TMonitor.Exit(TicketCacheLock);
  end;
end;

constructor TTicketLookupDialogState.Create(AConnection: TDBConnection; ATicketEdit: TEdit; AInfoLabel: TLabel;
  ALookupButton: TButton; const InitialInfo: TSqlMonitorTicketInfo; InitialInfoAvailable: Boolean);
begin
  inherited Create;
  FConnection := AConnection;
  FTicketEdit := ATicketEdit;
  FInfoLabel := AInfoLabel;
  FLookupButton := ALookupButton;
  FLoadedInfo := EmptyTicketInfo;
  if InitialInfoAvailable then
    FLoadedInfo := InitialInfo;
  FTicketEdit.OnChange := TicketEditChange;
  FLookupButton.OnClick := LookupButtonClick;
  TicketEditChange(FTicketEdit);
end;


function TTicketLookupDialogState.CurrentTicketNumber: String;
begin
  Result := Trim(FTicketEdit.Text);
end;


procedure TTicketLookupDialogState.SetInfoMessage(const Msg: String; Color: TColor);
begin
  FInfoLabel.Font.Color := Color;
  FInfoLabel.Caption := Msg;
  FInfoLabel.Update;
end;


procedure TTicketLookupDialogState.TicketEditChange(Sender: TObject);
var
  TicketNumber, MessageText: String;
begin
  TicketNumber := CurrentTicketNumber;
  if TicketNumber.IsEmpty then begin
    SetInfoMessage(SqlMonitorTranslate('Type a ticket number and load the title to confirm it.'), clGrayText);
    Exit;
  end;

  if SameText(TicketNumber, FLoadedInfo.Number) and (not FLoadedInfo.Title.IsEmpty) then begin
    MessageText := Format(SqlMonitorTranslate('Ticket %s: %s'), [FLoadedInfo.Number, FLoadedInfo.Title]);
    if not FLoadedInfo.Status.IsEmpty then
      MessageText := MessageText + ' (' + FLoadedInfo.Status + ')';
    SetInfoMessage(MessageText, clWindowText);
  end else begin
    SetInfoMessage(SqlMonitorTranslate('Click Load ticket title to confirm this ticket.'), clGrayText);
  end;
end;


procedure TTicketLookupDialogState.LookupButtonClick(Sender: TObject);
begin
  LoadTicketInfo(True);
end;


function TTicketLookupDialogState.LoadTicketInfo(ShowErrors: Boolean): Boolean;
var
  Client: TSqlMonitorClient;
  TicketNumber, TicketTitle, TicketStatus, MessageText: String;
begin
  Result := False;
  TicketNumber := CurrentTicketNumber;
  if TicketNumber.IsEmpty then begin
    SetInfoMessage(SqlMonitorTranslate('Type a ticket number and load the title to confirm it.'), clRed);
    Exit;
  end;

  SetInfoMessage(SqlMonitorTranslate('Loading ticket title ...'), clGrayText);
  Client := TSqlMonitorClient.Create(FInfoLabel);
  try
    try
      Result := Client.LookupTicket(FConnection, TicketNumber, TicketTitle, TicketStatus);
    except
      on E: Exception do begin
        if ShowErrors then
          SetInfoMessage(SqlMonitorTranslate('Ticket lookup failed: ') + E.Message, clRed)
        else
          SetInfoMessage(SqlMonitorTranslate('Click Load ticket title to confirm this ticket.'), clGrayText);
        Exit(False);
      end;
    end;
  finally
    Client.Free;
  end;

  FLoadedInfo.Number := TicketNumber;
  FLoadedInfo.Title := TicketTitle;
  FLoadedInfo.Status := TicketStatus;
  CacheTicketInfo(FConnection, FLoadedInfo);
  MessageText := Format(SqlMonitorTranslate('Ticket %s: %s'), [FLoadedInfo.Number, FLoadedInfo.Title]);
  if not FLoadedInfo.Status.IsEmpty then
    MessageText := MessageText + ' (' + FLoadedInfo.Status + ')';
  SetInfoMessage(MessageText, clWindowText);
end;

function ReadAppSettingSafely(SettingIndex: TAppSettingIndex): String;
begin
  Result := '';
  if not Assigned(AppSettings) then
    Exit;
  System.TMonitor.Enter(AppSettings);
  try
    AppSettings.StorePath;
    try
      Result := Trim(AppSettings.ReadString(SettingIndex));
    finally
      AppSettings.RestorePath;
    end;
  finally
    System.TMonitor.Exit(AppSettings);
  end;
end;


function ReadAppSettingBoolSafely(SettingIndex: TAppSettingIndex): Boolean;
begin
  Result := False;
  if not Assigned(AppSettings) then
    Exit;
  System.TMonitor.Enter(AppSettings);
  try
    AppSettings.StorePath;
    try
      Result := AppSettings.ReadBool(SettingIndex);
    finally
      AppSettings.RestorePath;
    end;
  finally
    System.TMonitor.Exit(AppSettings);
  end;
end;


procedure EnsureSqlMonitorConfigurationLoaded;
begin
  System.TMonitor.Enter(SqlMonitorConfigLock);
  try
    if SqlMonitorConfigInitialized then
      Exit;
    CachedSqlMonitorUrl := ReadAppSettingSafely(asSqlMonitorUrl);
    if CachedSqlMonitorUrl.IsEmpty then
      CachedSqlMonitorUrl := Trim(GetEnvironmentVariable('HEIDISQL_SQLMONITOR_URL'));
    CachedSqlMonitorApiKey := ReadAppSettingSafely(asSqlMonitorApiKey);
    if CachedSqlMonitorApiKey.IsEmpty then
      CachedSqlMonitorApiKey := Trim(GetEnvironmentVariable('HEIDISQL_SQLMONITOR_API_KEY'));
    CachedSqlMonitorCentralAuthEnabled := ReadAppSettingBoolSafely(asSqlMonitorCentralAuthEnabled);
    SqlMonitorConfigInitialized := True;
  finally
    System.TMonitor.Exit(SqlMonitorConfigLock);
  end;
end;


procedure SqlMonitorRefreshConfiguration;
begin
  System.TMonitor.Enter(SqlMonitorConfigLock);
  try
    SqlMonitorConfigInitialized := False;
    CachedSqlMonitorUrl := '';
    CachedSqlMonitorApiKey := '';
    CachedSqlMonitorCentralAuthEnabled := False;
  finally
    System.TMonitor.Exit(SqlMonitorConfigLock);
  end;
  ClearCentralAuthSession;
end;


function GetConfiguredSqlMonitorUrl: String;
begin
  EnsureSqlMonitorConfigurationLoaded;
  Result := CachedSqlMonitorUrl;
end;


function GetSqlMonitorApiKey: String;
begin
  EnsureSqlMonitorConfigurationLoaded;
  Result := CachedSqlMonitorApiKey;
end;


function SqlMonitorCentralAuthEnabled: Boolean;
begin
  EnsureSqlMonitorConfigurationLoaded;
  if CSLOG_BUILD then
    Result := True
  else
    Result := CachedSqlMonitorCentralAuthEnabled;
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


function PromptForCentralAuthSession(const InitialError: String): Boolean;
var
  Dialog: TForm;
  PromptLabel, ErrorLabel, UserLabel, PasswordLabel: TLabel;
  UserEdit, PasswordEdit: TEdit;
  SignInButton, CancelButton: TButton;
  DialogState: TSqlMonitorCentralAuthDialogState;
begin
  Result := False;
  Dialog := TForm.CreateNew(MainForm);
  try
    Dialog.Caption := SqlMonitorTranslate('Centralized AD authentication');
    Dialog.BorderStyle := bsDialog;
    Dialog.Position := poDesigned;
    Dialog.Width := 470;
    Dialog.Height := 250;
    Dialog.Constraints.MinWidth := 430;
    Dialog.Constraints.MinHeight := 220;
    Dialog.BorderIcons := [biSystemMenu];

    PromptLabel := TLabel.Create(Dialog);
    PromptLabel.Parent := Dialog;
    PromptLabel.AutoSize := False;
    PromptLabel.WordWrap := True;
    PromptLabel.Caption := SqlMonitorTranslate('Sign in with your Active Directory credentials to continue.');
    PromptLabel.Anchors := [akLeft, akTop, akRight];

    ErrorLabel := TLabel.Create(Dialog);
    ErrorLabel.Parent := Dialog;
    ErrorLabel.AutoSize := False;
    ErrorLabel.WordWrap := True;
    ErrorLabel.Font.Color := clRed;
    ErrorLabel.Anchors := [akLeft, akTop, akRight];

    UserLabel := TLabel.Create(Dialog);
    UserLabel.Parent := Dialog;
    UserLabel.Caption := SqlMonitorTranslate('User name');

    UserEdit := TEdit.Create(Dialog);
    UserEdit.Parent := Dialog;
    UserEdit.Anchors := [akLeft, akTop, akRight];
    UserEdit.Text := GetCurrentCentralAuthUsername;
    UserLabel.FocusControl := UserEdit;

    PasswordLabel := TLabel.Create(Dialog);
    PasswordLabel.Parent := Dialog;
    PasswordLabel.Caption := SqlMonitorTranslate('Password');

    PasswordEdit := TEdit.Create(Dialog);
    PasswordEdit.Parent := Dialog;
    PasswordEdit.Anchors := [akLeft, akTop, akRight];
    PasswordEdit.PasswordChar := '*';
    PasswordLabel.FocusControl := PasswordEdit;

    SignInButton := TButton.Create(Dialog);
    SignInButton.Parent := Dialog;
    SignInButton.Width := 100;
    SignInButton.Height := 30;
    SignInButton.Anchors := [akRight, akBottom];
    SignInButton.Caption := SqlMonitorTranslate('Sign in');
    SignInButton.Default := True;
    SignInButton.ModalResult := mrOk;

    CancelButton := TButton.Create(Dialog);
    CancelButton.Parent := Dialog;
    CancelButton.Width := 90;
    CancelButton.Height := 30;
    CancelButton.Anchors := [akRight, akBottom];
    CancelButton.Caption := _('Cancel');
    CancelButton.Cancel := True;
    CancelButton.ModalResult := mrCancel;

    DialogState := TSqlMonitorCentralAuthDialogState.Create(Dialog, PromptLabel, ErrorLabel,
      UserLabel, UserEdit, PasswordLabel, PasswordEdit, SignInButton, CancelButton, InitialError);
    try
      Dialog.OnCloseQuery := DialogState.HandleCloseQuery;

      if Trim(UserEdit.Text) = '' then
        Dialog.ActiveControl := UserEdit
      else
        Dialog.ActiveControl := PasswordEdit;

      CenterFormOnActiveMonitor(Dialog);
      Result := Dialog.ShowModal = mrOk;
    finally
      DialogState.Free;
    end;
  finally
    Dialog.Free;
  end;
end;


function SqlMonitorEnsureStartupAuthentication: Boolean;
begin
  Result := True;
  if not SqlMonitorCentralAuthEnabled then
    Exit;
  if not TSqlMonitorClient.IsConfigured then begin
    SqlMonitorShowError(SqlMonitorTranslate('Centralized AD authentication failed'),
      SqlMonitorTranslate('Centralized AD authentication is enabled, but the SQL monitor URL or API key is missing.'));
    Exit(False);
  end;
  if HasValidCentralAuthToken then
    Exit(True);
  Result := PromptForCentralAuthSession('');
end;


function SqlMonitorEnsureCentralAuthSession(const InitialError: String=''): Boolean;
begin
  if HasValidCentralAuthToken then
    Exit(True);
  Result := PromptForCentralAuthSession(InitialError);
end;


function SqlMonitorHasValidCentralAuthToken: Boolean;
begin
  Result := HasValidCentralAuthToken;
end;


function SqlMonitorGetCurrentAuthToken: String;
begin
  Result := GetCurrentCentralAuthToken;
end;


function SqlMonitorGetApiKey: String;
begin
  Result := GetSqlMonitorApiKey;
end;


procedure SqlMonitorClearCentralAuthSession;
begin
  ClearCentralAuthSession;
end;

procedure SqlMonitorPrepareConnectionAuthentication(Connection: TDBConnection);
var
  Client: TSqlMonitorClient;
  Credentials: TSqlMonitorCredentialResponse;
  ShouldRetry: Boolean;
begin
  if not SqlMonitorCentralAuthEnabled then
    Exit;
  if not TSqlMonitorClient.SupportsCentralAuthConnection(Connection) then
    Exit;
  if not TSqlMonitorClient.IsConfigured then
    raise ESqlMonitorError.Create(SqlMonitorTranslate('Centralized AD authentication is enabled, but the SQL monitor URL or API key is missing.'));
  if not HasValidCentralAuthToken then begin
    if not PromptForCentralAuthSession('') then
      raise ESqlMonitorError.Create(SqlMonitorTranslate('Centralized AD authentication was cancelled by the user.'));
  end;

  Client := TSqlMonitorClient.Create(MainForm);
  try
    ShouldRetry := True;
    while True do begin
      try
        Credentials := Client.ResolveDbCredentials(Connection);
        Break;
      except
        on E:ESqlMonitorHttpError do begin
          if ShouldRetry and (E.StatusCode = 401) then begin
            ClearCentralAuthSession;
            ShouldRetry := False;
            if not PromptForCentralAuthSession(SqlMonitorTranslate('Centralized AD session expired. Sign in again to continue.')) then
              raise ESqlMonitorError.Create(SqlMonitorTranslate('Centralized AD authentication was cancelled by the user.'));
            Continue;
          end;
          raise;
        end;
      end;
    end;
  finally
    Client.Free;
  end;

  if Credentials.Mode = smcmManaged then begin
    if Credentials.DbUser.Trim.IsEmpty then
      raise ESqlMonitorError.Create(SqlMonitorTranslate('Managed DB credentials were not returned by the central service.'));
    Connection.SetCredentialOverride(Credentials.DbUser, Credentials.DbPassword);
  end;
end;


function StatementIsGuardedWrite(const SQL: String): Boolean;
var
  Command: String;
begin
  Command := UpperCase(getFirstWord(SQL));
  Result := (Command = 'UPDATE') or (Command = 'DELETE');
end;


function StatementIsWrite(const SQL: String): Boolean;
var
  Command: String;
begin
  Command := UpperCase(getFirstWord(SQL));
  Result := (Command = 'INSERT') or (Command = 'UPDATE') or (Command = 'DELETE');
end;


function StatementListHasGuardedWrites(StatementSql: TStrings): Boolean;
var
  i: Integer;
begin
  Result := False;
  if StatementSql = nil then
    Exit;
  for i:=0 to StatementSql.Count-1 do begin
    if StatementIsGuardedWrite(StatementSql[i]) then begin
      Result := True;
      Break;
    end;
  end;
end;


function StatementListHasWrites(StatementSql: TStrings): Boolean;
var
  i: Integer;
begin
  Result := False;
  if StatementSql = nil then
    Exit;
  for i:=0 to StatementSql.Count-1 do begin
    if StatementIsWrite(StatementSql[i]) then begin
      Result := True;
      Break;
    end;
  end;
end;


function ConnectionNameContains(Connection: TDBConnection; const Token: String): Boolean;
var
  Haystack: String;
begin
  Result := False;
  if (Connection = nil) or Token.IsEmpty then
    Exit;
  Haystack := Connection.Parameters.SessionPath + ' ' + Connection.Parameters.SessionName + ' ' +
    Connection.Parameters.AllDatabasesStr + ' ' + Connection.Parameters.Comment + ' ' + Connection.Database;
  Result := Pos(UpperCase(Token), UpperCase(Haystack)) > 0;
end;


function SqlMonitorIsTestTarget(Connection: TDBConnection): Boolean;
begin
  Result := ConnectionNameContains(Connection, 'Teste');
end;


function SqlMonitorIsReplicaTarget(Connection: TDBConnection): Boolean;
begin
  Result := ConnectionNameContains(Connection, 'Espelho');
end;


function SqlMonitorIsProductionTarget(Connection: TDBConnection): Boolean;
begin
  Result := (Connection <> nil) and (not SqlMonitorIsTestTarget(Connection)) and
    (not SqlMonitorIsReplicaTarget(Connection));
end;


function SqlMonitorTargetDisplayName(Connection: TDBConnection): String;
begin
  Result := '';
  if Connection = nil then
    Exit;

  Result := Trim(Connection.Parameters.SessionName);
  if Result.IsEmpty then
    Result := Trim(Connection.Parameters.SessionPath);
  if Result.IsEmpty then
    Result := ResolveTargetDatabase(Connection, '');
  if Result.IsEmpty then
    Result := Trim(Connection.Parameters.Hostname);
end;


function BuildStatementPreview(StatementSql: TStrings): String;
var
  i, PreviewCount: Integer;
  Line: String;
begin
  Result := '';
  if (StatementSql = nil) or (StatementSql.Count = 0) then
    Exit;

  PreviewCount := Min(StatementSql.Count, 4);
  for i:=0 to PreviewCount-1 do begin
    Line := Trim(StringReplace(StringReplace(StatementSql[i], #13, ' ', [rfReplaceAll]), #10, ' ', [rfReplaceAll]));
    if (Line <> '') and (Line[Length(Line)] <> ';') then
      Line := Line + ';';
    if Length(Line) > 180 then
      Line := Copy(Line, 1, 177) + '...';
    if Result <> '' then
      Result := Result + sLineBreak;
    Result := Result + IntToStr(i+1) + '. ' + Line;
  end;
  if StatementSql.Count > PreviewCount then
    Result := Result + sLineBreak + '...';
end;


function PromptForTicketNumber(Connection: TDBConnection; StatementSql: TStrings; HasGuardedWrites: Boolean; out TicketNumber: String): Boolean;
var
  Dialog: TForm;
  IntroLabel, TicketLabel, TicketInfoLabel, TargetCaptionLabel, TargetValueLabel: TLabel;
  TicketEdit: TEdit;
  SummaryMemo: TMemo;
  ConfirmButton, CancelButton, LookupTicketButton: TButton;
  TicketController: TTicketLookupDialogState;
  CachedInfo, LoadedInfo: TSqlMonitorTicketInfo;
  HasCachedInfo: Boolean;
  SummaryText, PreviewText, TargetDisplayName: String;
  IntroRect, TargetRect: TRect;
  IsProductionTarget: Boolean;
begin
  Result := False;
  TicketNumber := '';
  TicketController := nil;
  IsProductionTarget := SqlMonitorIsProductionTarget(Connection);
  TargetDisplayName := SqlMonitorTargetDisplayName(Connection);
  Dialog := TForm.CreateNew(MainForm);
  try
    Dialog.Caption := SqlMonitorTranslate('Confirm SQL write');
    Dialog.BorderStyle := bsSizeable;
    Dialog.Position := poMainFormCenter;
    Dialog.Width := 720;
    Dialog.Height := 390;
    Dialog.Constraints.MinWidth := 560;
    Dialog.Constraints.MinHeight := 330;
    Dialog.BorderIcons := [biSystemMenu, biMaximize];

    TargetCaptionLabel := TLabel.Create(Dialog);
    TargetCaptionLabel.Parent := Dialog;
    TargetCaptionLabel.SetBounds(16, 16, Dialog.ClientWidth - 32, 18);
    TargetCaptionLabel.Anchors := [akLeft, akTop, akRight];
    TargetCaptionLabel.AutoSize := False;
    TargetCaptionLabel.Caption := SqlMonitorTranslate('Execution target');
    TargetCaptionLabel.Font.Style := [fsBold];

    TargetValueLabel := TLabel.Create(Dialog);
    TargetValueLabel.Parent := Dialog;
    TargetValueLabel.SetBounds(16, TargetCaptionLabel.Top + TargetCaptionLabel.Height + 4, Dialog.ClientWidth - 32, 24);
    TargetValueLabel.Anchors := [akLeft, akTop, akRight];
    TargetValueLabel.AutoSize := False;
    TargetValueLabel.WordWrap := True;
    TargetValueLabel.Caption := TargetDisplayName;
    TargetValueLabel.Font.Style := [fsBold];
    if IsProductionTarget then
      TargetValueLabel.Font.Color := clRed;
    TargetRect := Rect(0, 0, TargetValueLabel.Width, 0);
    DrawText(TargetValueLabel.Canvas.Handle, PChar(TargetValueLabel.Caption), Length(TargetValueLabel.Caption), TargetRect,
      DT_CALCRECT or DT_WORDBREAK or DT_LEFT);
    TargetValueLabel.Height := TargetRect.Bottom - TargetRect.Top + 4;

    IntroLabel := TLabel.Create(Dialog);
    IntroLabel.Parent := Dialog;
    IntroLabel.SetBounds(16, TargetValueLabel.Top + TargetValueLabel.Height + 10, Dialog.ClientWidth - 32, 24);
    IntroLabel.Anchors := [akLeft, akTop, akRight];
    IntroLabel.AutoSize := False;
    IntroLabel.WordWrap := True;
    IntroLabel.Caption := SqlMonitorTranslate('Confirm this SQL write before it is executed. You may also inform a ticket number.');
    IntroRect := Rect(0, 0, IntroLabel.Width, 0);
    DrawText(IntroLabel.Canvas.Handle, PChar(IntroLabel.Caption), Length(IntroLabel.Caption), IntroRect,
      DT_CALCRECT or DT_WORDBREAK or DT_LEFT);
    IntroLabel.Height := IntroRect.Bottom - IntroRect.Top + 4;

    TicketLabel := TLabel.Create(Dialog);
    TicketLabel.Parent := Dialog;
    TicketLabel.Left := 16;
    TicketLabel.Top := IntroLabel.Top + IntroLabel.Height + 12;
    TicketLabel.Caption := SqlMonitorTranslate('Ticket number');

    LookupTicketButton := TButton.Create(Dialog);
    LookupTicketButton.Parent := Dialog;
    LookupTicketButton.Width := 132;
    LookupTicketButton.Height := 24;
    LookupTicketButton.Left := Dialog.ClientWidth - 16 - LookupTicketButton.Width;
    LookupTicketButton.Top := TicketLabel.Top + TicketLabel.Height + 6;
    LookupTicketButton.Anchors := [akTop, akRight];
    LookupTicketButton.Caption := SqlMonitorTranslate('Load ticket title');

    TicketEdit := TEdit.Create(Dialog);
    TicketEdit.Parent := Dialog;
    TicketEdit.Left := 16;
    TicketEdit.Top := LookupTicketButton.Top;
    TicketEdit.Width := LookupTicketButton.Left - TicketEdit.Left - 8;
    TicketEdit.Anchors := [akLeft, akTop, akRight];
    HasCachedInfo := GetCachedTicketInfo(Connection, CachedInfo);
    if HasCachedInfo then
      TicketEdit.Text := CachedInfo.Number;
    TicketLabel.FocusControl := TicketEdit;

    TicketInfoLabel := TLabel.Create(Dialog);
    TicketInfoLabel.Parent := Dialog;
    TicketInfoLabel.Left := 16;
    TicketInfoLabel.Top := TicketEdit.Top + TicketEdit.Height + 6;
    TicketInfoLabel.Width := Dialog.ClientWidth - 32;
    TicketInfoLabel.Height := 34;
    TicketInfoLabel.Anchors := [akLeft, akTop, akRight];
    TicketInfoLabel.AutoSize := False;
    TicketInfoLabel.WordWrap := True;

    TicketController := TTicketLookupDialogState.Create(Connection, TicketEdit, TicketInfoLabel,
      LookupTicketButton, CachedInfo, HasCachedInfo);

    SummaryMemo := TMemo.Create(Dialog);
    SummaryMemo.Parent := Dialog;
    SummaryMemo.Left := 16;
    SummaryMemo.Top := TicketInfoLabel.Top + TicketInfoLabel.Height + 12;
    SummaryMemo.Width := Dialog.ClientWidth - 32;
    SummaryMemo.Height := Dialog.ClientHeight - SummaryMemo.Top - 56;
    SummaryMemo.Anchors := [akLeft, akTop, akRight, akBottom];
    SummaryMemo.ReadOnly := True;
    SummaryMemo.ScrollBars := ssVertical;
    SummaryMemo.WordWrap := True;
    SummaryMemo.TabStop := False;
    if HasGuardedWrites then
      SummaryText := SqlMonitorTranslate('This write will wait for centralized approval after you confirm the ticket number.')
    else
      SummaryText := SqlMonitorTranslate('This write will be logged centrally after you confirm the ticket number.');
    PreviewText := BuildStatementPreview(StatementSql);
    if not PreviewText.IsEmpty then
      SummaryText := SummaryText + sLineBreak + sLineBreak + PreviewText;
    SummaryMemo.Lines.Text := SummaryText;

    ConfirmButton := TButton.Create(Dialog);
    ConfirmButton.Parent := Dialog;
    ConfirmButton.Width := 100;
    ConfirmButton.Height := 30;
    ConfirmButton.Left := Dialog.ClientWidth - 216;
    ConfirmButton.Top := Dialog.ClientHeight - 44;
    ConfirmButton.Anchors := [akRight, akBottom];
    ConfirmButton.Caption := SqlMonitorTranslate('Confirm');
    ConfirmButton.Default := True;
    ConfirmButton.ModalResult := mrOk;

    CancelButton := TButton.Create(Dialog);
    CancelButton.Parent := Dialog;
    CancelButton.Width := 90;
    CancelButton.Height := 30;
    CancelButton.Left := Dialog.ClientWidth - 104;
    CancelButton.Top := Dialog.ClientHeight - 44;
    CancelButton.Anchors := [akRight, akBottom];
    CancelButton.Caption := _('Cancel');
    CancelButton.Cancel := True;
    CancelButton.ModalResult := mrCancel;

    Dialog.ActiveControl := TicketEdit;
    if Dialog.ShowModal <> mrOk then
      Exit(False);
    TicketNumber := Trim(TicketEdit.Text);
    LoadedInfo := TicketController.LoadedInfo;
    if SameText(LoadedInfo.Number, TicketNumber) and (not LoadedInfo.Title.IsEmpty) then
      CacheTicketInfo(Connection, LoadedInfo)
    else
      CacheTicketNumber(Connection, TicketNumber);
    Result := True;
  finally
    TicketController.Free;
    Dialog.Free;
  end;
end;

function SqlMonitorPrepareExecution(Connection: TDBConnection; StatementSql: TStrings; out Context: TSqlMonitorExecutionContext): Boolean;
var
  Client: TSqlMonitorClient;
  Response: TSqlMonitorBatchResponse;
  HasGuardedWrites, HasWrites: Boolean;
  DecisionMsg, RequestId, TicketNumber, ErrorTitle: String;
begin
  Result := True;
  Context := nil;
  if (StatementSql = nil) or (StatementSql.Count = 0) then
    Exit;

  HasGuardedWrites := StatementListHasGuardedWrites(StatementSql);
  HasWrites := StatementListHasWrites(StatementSql);
  TicketNumber := '';

  if CSLOG_BUILD and HasWrites and SqlMonitorIsReplicaTarget(Connection) then begin
    DecisionMsg := SqlMonitorTranslate('Writes are blocked for Espelho replica databases.');
    if Assigned(MainForm) then
      MainForm.LogSQL(SqlMonitorTranslate('SQL monitor blocked execution: ') + DecisionMsg, lcError, Connection);
    SqlMonitorShowError(SqlMonitorTranslate('Central SQL approval blocked execution'), DecisionMsg);
    Result := False;
    Exit;
  end;

  if not SqlMonitorShouldHandle(Connection) then
    Exit;

  if HasWrites and (not SqlMonitorIsTestTarget(Connection)) then begin
    if not PromptForTicketNumber(Connection, StatementSql, HasGuardedWrites, TicketNumber) then begin
      Result := False;
      Exit;
    end;
  end;

  try
    Client := TSqlMonitorClient.Create(MainForm);
    try
      Response := Client.CreateRequest(Connection, StatementSql, TicketNumber);
      try
        if HasGuardedWrites and (Response.Status = smbsPending) then begin
          RequestId := Response.RequestId;
          if RequestId.IsEmpty then
            raise ESqlMonitorError.Create(SqlMonitorTranslate('Central SQL approval request returned no request id.'));
          if Assigned(MainForm) then
            MainForm.ShowStatusMsg(SqlMonitorTranslate('Waiting for centralized SQL approval ...'));
          Response.Free;
          Response := nil;
          Client.WaitForDecision(RequestId, Response);
        end;

        if HasGuardedWrites and SqlMonitorIsProductionTarget(Connection) and (Response.Status = smbsApproved) then begin
          DecisionMsg := Format('%s'#13#10#13#10'%s',
            [SqlMonitorTranslate('API approval confirmed this production write. Do you want to execute it now?'),
             SqlMonitorTargetDisplayName(Connection)]);
          if MessageDialog(SqlMonitorTranslate('Confirm production execution'), DecisionMsg, mtWarning, [mbYes, mbCancel]) <> mrYes then begin
            if Assigned(MainForm) then
              MainForm.LogSQL(SqlMonitorTranslate('SQL monitor blocked execution: ') +
                SqlMonitorTranslate('Production execution was cancelled by the user after API approval.'), lcError, Connection);
            Result := False;
            Exit;
          end;
        end;

        if HasWrites then begin
          if (Response.Status in [smbsLogged, smbsApproved]) and (not Response.RequestId.IsEmpty) then
            Context := TSqlMonitorExecutionContext.Create(Response.RequestId, StatementSql)
          else begin
            DecisionMsg := SqlMonitorGetDecisionMessage(Response);
            if DecisionMsg.IsEmpty then begin
              if HasGuardedWrites then
                DecisionMsg := SqlMonitorTranslate('Central SQL approval rejected this batch.')
              else
                DecisionMsg := SqlMonitorTranslate('Central SQL write registration failed.');
            end;
            if Assigned(MainForm) then begin
              if HasGuardedWrites then begin
                MainForm.LogSQL(SqlMonitorTranslate('SQL monitor blocked execution: ') + DecisionMsg, lcError, Connection);
                ErrorTitle := _('Central SQL approval blocked execution');
              end else begin
                MainForm.LogSQL(SqlMonitorTranslate('SQL monitor write registration failed: ') + DecisionMsg, lcError, Connection);
                ErrorTitle := SqlMonitorTranslate('Central SQL write registration failed');
              end;
              SqlMonitorShowError(ErrorTitle, DecisionMsg);
            end;
            Result := False;
          end;
        end else begin
          if (Response.Status in [smbsLogged, smbsApproved]) and (not Response.RequestId.IsEmpty) then
            Context := TSqlMonitorExecutionContext.Create(Response.RequestId, StatementSql)
          else if not (Response.Status in [smbsLogged, smbsApproved]) then begin
            DecisionMsg := SqlMonitorGetDecisionMessage(Response);
            if DecisionMsg.IsEmpty then
              DecisionMsg := SqlMonitorTranslate('Central SQL logging is unavailable. Continuing without centralized logging.');
            if Assigned(MainForm) then begin
              MainForm.LogSQL(SqlMonitorTranslate('SQL monitor logging warning: ') + DecisionMsg, lcError);
              MainForm.ShowStatusMsg(SqlMonitorTranslate('Central SQL logging is unavailable. Continuing without centralized logging.'));
            end;
          end;
        end;
      finally
        Response.Free;
      end;
    finally
      Client.Free;
    end;
  except
    on E:Exception do begin
      if HasWrites then begin
        if Assigned(MainForm) then begin
          if HasGuardedWrites then begin
            MainForm.LogSQL(SqlMonitorTranslate('SQL monitor approval failed: ') + E.Message, lcError, Connection);
            SqlMonitorShowError(_('Central SQL approval failed'), E.Message);
          end else begin
            MainForm.LogSQL(SqlMonitorTranslate('SQL monitor write registration failed: ') + E.Message, lcError, Connection);
            SqlMonitorShowError(SqlMonitorTranslate('Central SQL write registration failed'), E.Message);
          end;
        end;
        Result := False;
      end else begin
        if Assigned(MainForm) then begin
          MainForm.LogSQL(SqlMonitorTranslate('SQL monitor logging warning: ') + E.Message, lcError);
          MainForm.ShowStatusMsg(_('Central SQL logging is unavailable. Continuing without centralized logging.'));
        end;
      end;
    end;
  end;

  if not Result then
    FreeAndNil(Context);
end;


function SqlMonitorPrepareSingleExecution(Connection: TDBConnection; const SQL: String; out Context: TSqlMonitorExecutionContext): Boolean;
var
  StatementSql: TStringList;
begin
  if SQL.Trim.IsEmpty then begin
    Context := nil;
    Result := True;
    Exit;
  end;
  StatementSql := TStringList.Create;
  try
    StatementSql.Add(SQL);
    Result := SqlMonitorPrepareExecution(Connection, StatementSql, Context);
  finally
    StatementSql.Free;
  end;
end;


procedure SqlMonitorLogExecutedStatement(Connection: TDBConnection; const SQL: String; DurationMs: Cardinal; RowsAffected, RowsFound: Int64; const TicketNumber: String='');
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
    Payload := Client.BuildExecutionPayload(Connection, SQL, TicketNumber, DurationMs, RowsAffected, RowsFound, True, '');
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
  if not TSqlMonitorClient.SupportsSessionConnection(Connection) then
    Exit;

  EffectiveDatabase := ResolveTargetDatabase(Connection, DatabaseName);
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
  Result := NormalizeUrl(GetConfiguredSqlMonitorUrl);
end;


class function TSqlMonitorClient.CentralAuthEnabled: Boolean;
begin
  Result := SqlMonitorCentralAuthEnabled;
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


class function TSqlMonitorClient.SupportsCentralAuthConnection(Connection: TDBConnection): Boolean;
begin
  Result := CentralAuthEnabled and IsConfigured and Assigned(Connection)
    and (not Connection.Parameters.IsAnySQLite)
    and (not Connection.Parameters.WindowsAuth)
    and (not Trim(Connection.Parameters.Hostname).IsEmpty);
end;


class function TSqlMonitorClient.SupportsConnection(Connection: TDBConnection): Boolean;
begin
  Result := IsConfigured and Assigned(Connection) and Connection.Parameters.IsAnyMySQL;
end;


class function TSqlMonitorClient.SupportsSessionConnection(Connection: TDBConnection): Boolean;
begin
  Result := IsConfigured and Assigned(Connection) and (not Connection.Parameters.IsAnySQLite)
    and (not Trim(Connection.Parameters.Hostname).IsEmpty);
end;


class function TSqlMonitorClient.TryGetSettingInt(const Name: String; DefaultValue: Integer): Integer;
begin
  Result := StrToIntDef(GetEnvironmentVariable(Name), DefaultValue);
end;


function TSqlMonitorClient.BuildAuthLoginPayload(const Username, Password: String): String;
var
  RootJson: TJSONObject;
begin
  RootJson := TJSONObject.Create;
  try
    RootJson.AddPair('client_app', APPNAME);
    RootJson.AddPair('client_version', GetClientVersion);
    RootJson.AddPair('client_host', GetClientHostName);
    RootJson.AddPair('username', Username);
    RootJson.AddPair('password', Password);
    Result := RootJson.ToJSON;
  finally
    RootJson.Free;
  end;
end;


function TSqlMonitorClient.BuildCredentialResolvePayload(Connection: TDBConnection): String;
var
  RootJson, TargetJson: TJSONObject;
begin
  RootJson := TJSONObject.Create;
  try
    RootJson.AddPair('client_app', APPNAME);
    RootJson.AddPair('client_version', GetClientVersion);
    RootJson.AddPair('client_host', GetClientHostName);

    TargetJson := TJSONObject.Create;
    TargetJson.AddPair('host', Connection.Parameters.Hostname);
    TargetJson.AddPair('port', TJSONNumber.Create(GetConnectionTargetPort(Connection)));
    TargetJson.AddPair('database', ResolveTargetDatabase(Connection, ''));
    TargetJson.AddPair('db_user', Connection.Parameters.Username);
    TargetJson.AddPair('net_type', Connection.Parameters.NetTypeName(True));
    RootJson.AddPair('target', TargetJson);
    Result := RootJson.ToJSON;
  finally
    RootJson.Free;
  end;
end;


function TSqlMonitorClient.BuildTargetJson(Connection: TDBConnection; const DatabaseName: String): TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('host', Connection.Parameters.Hostname);
  Result.AddPair('port', TJSONNumber.Create(GetConnectionTargetPort(Connection)));
  Result.AddPair('database', ResolveTargetDatabase(Connection, DatabaseName));
  Result.AddPair('db_user', Connection.Parameters.Username);
  Result.AddPair('net_type', Connection.Parameters.NetTypeName(True));
end;


function TSqlMonitorClient.BuildSessionPayload(Connection: TDBConnection; const DatabaseName: String): String;
var
  RootJson: TJSONObject;
begin
  RootJson := TJSONObject.Create;
  try
    RootJson.AddPair('client_app', APPNAME);
    RootJson.AddPair('actor_id', GetClientActorId);
    RootJson.AddPair('client_host', GetClientHostName);
    RootJson.AddPair('client_version', GetClientVersion);
    RootJson.AddPair('target', BuildTargetJson(Connection, DatabaseName));
    Result := RootJson.ToJSON;
  finally
    RootJson.Free;
  end;
end;


function TSqlMonitorClient.BuildTicketLookupPayload(Connection: TDBConnection; const TicketNumber: String): String;
var
  RootJson: TJSONObject;
begin
  RootJson := TJSONObject.Create;
  try
    RootJson.AddPair('client_app', APPNAME);
    RootJson.AddPair('client_version', GetClientVersion);
    RootJson.AddPair('actor_id', GetClientActorId);
    RootJson.AddPair('client_host', GetClientHostName);
    RootJson.AddPair('ticket_number', TicketNumber);
    RootJson.AddPair('target', BuildTargetJson(Connection, ''));
    Result := RootJson.ToJSON;
  finally
    RootJson.Free;
  end;
end;

function TSqlMonitorClient.BuildExecutionPayload(Connection: TDBConnection; const SQL, TicketNumber: String; DurationMs: Cardinal; RowsAffected, RowsFound: Int64; Success: Boolean; const ErrorMessage: String): String;
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
    if not TicketNumber.IsEmpty then
      RootJson.AddPair('ticket_number', TicketNumber);

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


function TSqlMonitorClient.BuildRequestPayload(Connection: TDBConnection; StatementSql: TStrings; const TicketNumber: String): String;
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
    if not TicketNumber.IsEmpty then
      RootJson.AddPair('ticket_number', TicketNumber);

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


function TSqlMonitorClient.LoginCentralAuth(const Username, Password: String; out ActorId, AuthToken: String; out ExpiresAt: TDateTime): Boolean;
var
  ResponseText, ExpiresText: String;
  RootValue: TJSONValue;
  RootObject: TJSONObject;
begin
  Result := False;
  ActorId := '';
  AuthToken := '';
  ExpiresAt := 0;

  SendJsonRequest(BaseUrl + '/v1/auth/login', 'POST', BuildAuthLoginPayload(Username, Password), ResponseText, SessionTimeoutSeconds);
  RootValue := TJSONObject.ParseJSONValue(ResponseText);
  if not (RootValue is TJSONObject) then begin
    RootValue.Free;
    raise ESqlMonitorError.Create(SqlMonitorTranslate('SQL monitor returned an invalid JSON payload.'));
  end;

  RootObject := RootValue as TJSONObject;
  try
    ActorId := GetJsonString(RootObject, 'actor_id');
    if ActorId.IsEmpty then
      ActorId := Trim(Username);
    AuthToken := GetJsonString(RootObject, 'auth_token');
    if AuthToken.IsEmpty then
      raise ESqlMonitorError.Create(SqlMonitorTranslate('Centralized AD login did not return an auth token.'));
    ExpiresText := GetJsonString(RootObject, 'expires_at');
    if not TryParseCentralAuthExpiration(ExpiresText, ExpiresAt) then
      ExpiresAt := IncHour(Now, 8);
    Result := True;
  finally
    RootValue.Free;
  end;
end;


function TSqlMonitorClient.ParseCredentialResponse(const JsonText: String): TSqlMonitorCredentialResponse;
var
  RootValue: TJSONValue;
  RootObject: TJSONObject;
  ModeText: String;
begin
  Result.Mode := smcmBypass;
  Result.DbUser := '';
  Result.DbPassword := '';
  Result.Reason := '';
  if JsonText.Trim.IsEmpty then
    Exit;

  RootValue := TJSONObject.ParseJSONValue(JsonText);
  if not (RootValue is TJSONObject) then begin
    RootValue.Free;
    raise ESqlMonitorError.Create(SqlMonitorTranslate('SQL monitor returned an invalid JSON payload.'));
  end;

  RootObject := RootValue as TJSONObject;
  try
    ModeText := LowerCase(GetJsonString(RootObject, 'mode'));
    if ModeText = 'managed' then
      Result.Mode := smcmManaged
    else if ModeText = 'bypass' then
      Result.Mode := smcmBypass
    else
      raise ESqlMonitorError.Create(SqlMonitorTranslate('Centralized DB credential resolution returned an invalid mode.'));
    Result.DbUser := GetJsonString(RootObject, 'db_user');
    Result.DbPassword := GetJsonString(RootObject, 'db_password');
    Result.Reason := GetJsonString(RootObject, 'reason');
  finally
    RootValue.Free;
  end;
end;


function TSqlMonitorClient.LookupTicket(Connection: TDBConnection; const TicketNumber: String; out TicketTitle, TicketStatus: String): Boolean;
var
  ResponseText: String;
  RootValue: TJSONValue;
  RootObject: TJSONObject;
begin
  Result := False;
  TicketTitle := '';
  TicketStatus := '';
  SendJsonRequest(BaseUrl + '/v1/tickets/lookup', 'POST', BuildTicketLookupPayload(Connection, TicketNumber), ResponseText, SessionTimeoutSeconds);
  RootValue := TJSONObject.ParseJSONValue(ResponseText);
  if not (RootValue is TJSONObject) then begin
    RootValue.Free;
    raise ESqlMonitorError.Create(SqlMonitorTranslate('SQL monitor returned an invalid JSON payload.'));
  end;

  RootObject := RootValue as TJSONObject;
  try
    TicketTitle := GetJsonString(RootObject, 'title');
    TicketStatus := GetJsonString(RootObject, 'status');
    Result := True;
  finally
    RootValue.Free;
  end;
end;

function TSqlMonitorClient.ResolveDbCredentials(Connection: TDBConnection): TSqlMonitorCredentialResponse;
var
  ResponseText: String;
begin
  SendJsonRequest(BaseUrl + '/v1/db-credentials/resolve', 'POST', BuildCredentialResolvePayload(Connection), ResponseText, SessionTimeoutSeconds);
  Result := ParseCredentialResponse(ResponseText);
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


function TSqlMonitorClient.CreateRequest(Connection: TDBConnection; StatementSql: TStrings; const TicketNumber: String=''): TSqlMonitorBatchResponse;
var
  ResponseText: String;
begin
  SendJsonRequest(BaseUrl + '/v1/sql-requests', 'POST', BuildRequestPayload(Connection, StatementSql, TicketNumber), ResponseText);
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
  AuthToken: String;
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
    AuthToken := GetCurrentCentralAuthToken;
    if (not AuthToken.IsEmpty) and (Pos('/v1/auth/login', LowerCase(URL)) = 0) then
      Http.RequestHeaders.Values['Authorization'] := 'Bearer ' + AuthToken;
    if not SameText(Method, 'GET') then
      Http.RequestBody := Payload;
    Http.SendRequest('');
    ResponseText := Http.LastContent;
    Result := Http.StatusCode;
    if (Result < 200) or (Result > 299) then begin
      StatusText := ParseApiErrorMessage(ResponseText);
      if StatusText.IsEmpty then
        StatusText := f_('HTTP status %d', [Result]);
      raise ESqlMonitorHttpError.Create(Result, StatusText);
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
    StatusLabel.SetBounds(16, 16, Dialog.ClientWidth - 32, 24);
    StatusLabel.Anchors := [akLeft, akTop, akRight];
    StatusLabel.AutoSize := False;
    StatusLabel.WordWrap := False;
    StatusLabel.ShowAccelChar := False;
    StatusLabel.Caption := SqlMonitorTranslate('Submitting SQL approval request ...');

    HintMemo := TMemo.Create(Dialog);
    HintMemo.Parent := Dialog;
    HintMemo.SetBounds(16, StatusLabel.Top + StatusLabel.Height + 12, Dialog.ClientWidth - 32,
      Dialog.ClientHeight - StatusLabel.Top - StatusLabel.Height - 68);
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
    CancelButton.Anchors := [akRight, akBottom];
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


constructor TSqlMonitorCentralAuthDialogState.Create(ADialog: TForm; APromptLabel, AErrorLabel,
  AUserLabel: TLabel; AUserEdit: TEdit; APasswordLabel: TLabel; APasswordEdit: TEdit;
  ASignInButton, ACancelButton: TButton; const InitialError: String);
begin
  inherited Create;
  FDialog := ADialog;
  FPromptLabel := APromptLabel;
  FErrorLabel := AErrorLabel;
  FUserLabel := AUserLabel;
  FUserEdit := AUserEdit;
  FPasswordLabel := APasswordLabel;
  FPasswordEdit := APasswordEdit;
  FSignInButton := ASignInButton;
  FCancelButton := ACancelButton;
  SetError(InitialError);
end;


procedure TSqlMonitorCentralAuthDialogState.SetError(const Msg: String);
begin
  FErrorLabel.Caption := Trim(Msg);
  UpdateLayout;
end;


procedure TSqlMonitorCentralAuthDialogState.UpdateLayout;
const
  Margin = 16;
  LabelSpacing = 4;
  SectionSpacing = 10;
  ButtonSpacing = 12;
var
  Y: Integer;
  ButtonsTop: Integer;
  RequiredHeight: Integer;
  MeasureRect: TRect;

  function CalcLabelHeight(ALabel: TLabel; const Text: String): Integer;
  begin
    if Trim(Text) = '' then
      Exit(0);
    FDialog.HandleNeeded;
    FDialog.Canvas.Font.Assign(ALabel.Font);
    MeasureRect := Rect(0, 0, FDialog.ClientWidth - (Margin * 2), 0);
    DrawText(FDialog.Canvas.Handle, PChar(Text), Length(Text), MeasureRect,
      DT_LEFT or DT_WORDBREAK or DT_CALCRECT);
    Result := Max(MeasureRect.Height, FDialog.Canvas.TextHeight('Wy'));
  end;

begin
  FPromptLabel.SetBounds(Margin, Margin, FDialog.ClientWidth - (Margin * 2),
    Max(20, CalcLabelHeight(FPromptLabel, FPromptLabel.Caption)));

  Y := FPromptLabel.Top + FPromptLabel.Height + SectionSpacing;

  if FErrorLabel.Caption <> '' then begin
    FErrorLabel.Visible := True;
    FErrorLabel.SetBounds(Margin, Y, FDialog.ClientWidth - (Margin * 2),
      Max(18, CalcLabelHeight(FErrorLabel, FErrorLabel.Caption)));
    Y := FErrorLabel.Top + FErrorLabel.Height + 8;
  end else begin
    FErrorLabel.Visible := False;
    FErrorLabel.SetBounds(Margin, Y, FDialog.ClientWidth - (Margin * 2), 0);
  end;

  FUserLabel.Left := Margin;
  FUserLabel.Top := Y;

  FUserEdit.SetBounds(Margin, FUserLabel.Top + FUserLabel.Height + LabelSpacing,
    FDialog.ClientWidth - (Margin * 2), FUserEdit.Height);

  FPasswordLabel.Left := Margin;
  FPasswordLabel.Top := FUserEdit.Top + FUserEdit.Height + SectionSpacing;

  FPasswordEdit.SetBounds(Margin, FPasswordLabel.Top + FPasswordLabel.Height + LabelSpacing,
    FDialog.ClientWidth - (Margin * 2), FPasswordEdit.Height);

  RequiredHeight := FPasswordEdit.Top + FPasswordEdit.Height + FSignInButton.Height + 28;
  if FDialog.ClientHeight < RequiredHeight then
    FDialog.ClientHeight := RequiredHeight;

  ButtonsTop := FDialog.ClientHeight - FSignInButton.Height - 14;
  FCancelButton.SetBounds(FDialog.ClientWidth - FCancelButton.Width - Margin, ButtonsTop,
    FCancelButton.Width, FCancelButton.Height);
  FSignInButton.SetBounds(FCancelButton.Left - ButtonSpacing - FSignInButton.Width, ButtonsTop,
    FSignInButton.Width, FSignInButton.Height);
end;


procedure TSqlMonitorCentralAuthDialogState.HandleCloseQuery(Sender: TObject; var CanClose: Boolean);
var
  Client: TSqlMonitorClient;
  ActorId, AuthToken: String;
  ExpiresAt: TDateTime;
begin
  if FDialog.ModalResult <> mrOk then begin
    CanClose := True;
    Exit;
  end;

  CanClose := False;
  Client := TSqlMonitorClient.Create(FDialog);
  try
    try
      if Client.LoginCentralAuth(Trim(FUserEdit.Text), FPasswordEdit.Text, ActorId, AuthToken, ExpiresAt) then begin
        StoreCentralAuthSession(Trim(FUserEdit.Text), ActorId, AuthToken, ExpiresAt);
        SetError('');
        CanClose := True;
      end;
    except
      on E:Exception do begin
        SetError(E.Message);
        FPasswordEdit.Text := '';
        if Trim(FUserEdit.Text) = '' then
          FDialog.ActiveControl := FUserEdit
        else
          FDialog.ActiveControl := FPasswordEdit;
      end;
    end;
  finally
    Client.Free;
  end;
end;


procedure TSqlMonitorWaitState.HandleCancel(Sender: TObject);
begin
  Cancelled := True;
end;

initialization
  SessionRegistrations := TDictionary<NativeUInt, String>.Create;
  SessionRegistrationsLock := TObject.Create;
  SqlMonitorConfigLock := TObject.Create;
  SqlMonitorAuthLock := TObject.Create;
  TicketCacheLock := TObject.Create;
  CachedTicketInfo := TDictionary<String, TSqlMonitorTicketInfo>.Create;

finalization
  CachedTicketInfo.Free;
  TicketCacheLock.Free;
  SessionRegistrations.Free;
  SessionRegistrationsLock.Free;
  SqlMonitorConfigLock.Free;
  SqlMonitorAuthLock.Free;

end.





