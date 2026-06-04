<#
================================================================================
  Manutencao Completa do Windows  -  Ferramenta Visual
--------------------------------------------------------------------------------
  Aplicacao Windows Forms (PowerShell nativo, sem modulos externos) que executa
  uma rotina de manutencao mensal do Windows com interface grafica moderna.

  - Tema escuro moderno
  - Logs coloridos em tempo real (RichTextBox) + arquivo .txt
  - Barra de progresso visual
  - Execucao em background (UI nunca trava)
  - Cancelamento seguro via CancellationTokenSource
  - Auto-elevacao (UAC) + modo STA
  - Compativel com Windows 10 e Windows 11

  Etapas (equivalentes ao ManutencaoMensal.bat):
    1. Limpeza do cache DNS
    2. Limpeza de %TEMP%
    3. Limpeza de C:\Windows\Temp
    4. Limpeza de SoftwareDistribution\Download
    5. SFC /SCANNOW
    6. DISM /Online /Cleanup-Image /RestoreHealth
    7. CHKDSK C: /scan
    8. DISM /Online /Cleanup-Image /StartComponentCleanup
    9. Saude dos discos (Get-PhysicalDisk)
   10. Espaco livre (Get-Volume)

  Organizacao do codigo (regioes):
    1. Infra        -> elevacao (admin/STA), assemblies, paleta de cores
    2. Logs         -> escrita colorida em tempo real + arquivo
    3. ProgressBar  -> barra de progresso customizada
    4. Cancelamento -> CancellationTokenSource + helpers
    5. Execucao     -> helpers de processos e cada etapa de manutencao
    6. Orquestracao -> fluxo completo da manutencao
    7. UI           -> construcao da janela e eventos

  Uso: clique com o botao direito > "Executar com o PowerShell"
       (ele se reabre como Administrador automaticamente).
================================================================================
#>

# =============================================================================
# REGIAO 1 - INFRA: elevacao (Admin + STA) e carga de assemblies
# =============================================================================

# As tarefas de manutencao (SFC, DISM, CHKDSK, limpeza de pastas do sistema)
# exigem privilegios de Administrador. Detectamos a condicao e, se necessario,
# reabrimos o proprio script elevado e em modo STA (exigido pelo Windows Forms).
function Test-IsAdministrator {
    $identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Reabre o script com UAC. Retorna $true se conseguiu disparar a re-execucao.
function Invoke-SelfElevation {
    if ([string]::IsNullOrWhiteSpace($PSCommandPath)) {
        # Script colado no console (sem arquivo): nao da para re-executar sozinho.
        return $false
    }
    try {
        $psExe = (Get-Process -Id $PID).Path  # usa o mesmo host (powershell.exe)
        if ([string]::IsNullOrWhiteSpace($psExe)) { $psExe = 'powershell.exe' }
        $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-File', "`"$PSCommandPath`"")
        Start-Process -FilePath $psExe -ArgumentList $argList -Verb RunAs | Out-Null
        return $true
    }
    catch {
        return $false
    }
}

# Se nao for admin, tenta elevar e encerra a instancia atual.
if (-not (Test-IsAdministrator)) {
    if (Invoke-SelfElevation) { exit }
    # Se nao deu para elevar, segue mesmo assim: a UI avisara o usuario.
    [void][System.Reflection.Assembly]::LoadWithPartialName('System.Windows.Forms')
    [System.Windows.Forms.MessageBox]::Show(
        "Este aplicativo precisa ser executado como Administrador para realizar a manutencao.`r`n`r`nFeche e abra novamente com 'Executar como administrador'.",
        'Permissao necessaria', 'OK', 'Warning') | Out-Null
}

# Garante modo STA (Windows Forms nao funciona corretamente em MTA).
if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    if (-not [string]::IsNullOrWhiteSpace($PSCommandPath)) {
        $psExe = (Get-Process -Id $PID).Path
        if ([string]::IsNullOrWhiteSpace($psExe)) { $psExe = 'powershell.exe' }
        Start-Process -FilePath $psExe -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-STA','-File', "`"$PSCommandPath`"") | Out-Null
        exit
    }
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()
[System.Windows.Forms.Application]::SetCompatibleTextRenderingDefault($false)

# ---- Paleta (tema escuro moderno) -----------------------------------------
$Theme = @{
    Background  = [System.Drawing.Color]::FromArgb(30, 30, 46)    # fundo da janela
    Surface     = [System.Drawing.Color]::FromArgb(43, 43, 60)    # paineis / inputs
    SurfaceAlt  = [System.Drawing.Color]::FromArgb(24, 24, 37)    # area de logs
    Border      = [System.Drawing.Color]::FromArgb(69, 71, 90)
    Accent      = [System.Drawing.Color]::FromArgb(137, 180, 250) # azul
    AccentDark  = [System.Drawing.Color]::FromArgb(108, 142, 214)
    Text        = [System.Drawing.Color]::FromArgb(220, 224, 240)
    TextMuted   = [System.Drawing.Color]::FromArgb(150, 155, 175)
    Success     = [System.Drawing.Color]::FromArgb(166, 227, 161) # verde
    Warning     = [System.Drawing.Color]::FromArgb(249, 226, 175) # amarelo
    Error       = [System.Drawing.Color]::FromArgb(243, 139, 168) # vermelho
    Danger      = [System.Drawing.Color]::FromArgb(120, 50, 60)   # botao cancelar
}

$FontFamily = 'Segoe UI'

# Caminho de log padrao (igual ao .bat: Desktop\Manutencao_AAAAMMDD.txt).
$DefaultLogPath = Join-Path ([Environment]::GetFolderPath('Desktop')) `
    ("Manutencao_{0}.txt" -f (Get-Date -Format 'yyyyMMdd'))

# Variaveis de UI / estado (escopo de script).
$script:LogBox        = $null
$script:ProgressTrack = $null
$script:ProgressFill  = $null
$script:ProgressPct   = 0
$script:StatusLabel   = $null
$script:LogPath       = $DefaultLogPath
$script:Cts           = $null
$script:IsRunning     = $false


# =============================================================================
# REGIAO 2 - LOGS (cor em tempo real na UI + persistencia em arquivo .txt)
# =============================================================================

# Escreve uma linha colorida na area de logs e tambem grava no arquivo .txt.
# DoEvents() forca o repaint imediato para o log "aparecer ao vivo".
function Write-Log {
    param(
        [string]$Message,
        [ValidateSet('INFO', 'STEP', 'OK', 'WARN', 'ERROR')]
        [string]$Level = 'INFO'
    )

    $map = @{
        INFO  = @{ Icon = [char]0x2139; Color = $Theme.Text }      # i
        STEP  = @{ Icon = [char]0x25B6; Color = $Theme.Accent }    # >
        OK    = @{ Icon = [char]0x2714; Color = $Theme.Success }   # check
        WARN  = @{ Icon = [char]0x26A0; Color = $Theme.Warning }   # !
        ERROR = @{ Icon = [char]0x2716; Color = $Theme.Error }     # x
    }
    $info  = $map[$Level]
    $stamp = (Get-Date).ToString('HH:mm:ss')

    # --- Persistencia em arquivo .txt (com data e hora) ---------------------
    if (-not [string]::IsNullOrWhiteSpace($script:LogPath)) {
        try {
            $fullStamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
            Add-Content -Path $script:LogPath -Value "[$fullStamp] [$Level] $Message" -Encoding UTF8
        }
        catch { }
    }

    if ($null -eq $script:LogBox) { return }

    # Timestamp em cinza.
    $script:LogBox.SelectionStart  = $script:LogBox.TextLength
    $script:LogBox.SelectionColor  = $Theme.TextMuted
    $script:LogBox.AppendText("[$stamp] ")

    # Icone + mensagem na cor do nivel.
    $script:LogBox.SelectionColor  = $info.Color
    $script:LogBox.AppendText("$($info.Icon)  $Message`r`n")

    $script:LogBox.SelectionStart = $script:LogBox.TextLength
    $script:LogBox.ScrollToCaret()
    [System.Windows.Forms.Application]::DoEvents()
}

# Escreve uma linha "crua" (saida de um processo externo) sem icone, em cinza,
# tanto na UI quanto no arquivo. Usada para refletir a saida de SFC/DISM/CHKDSK.
function Write-RawLine {
    param([string]$Line)

    if ([string]::IsNullOrWhiteSpace($Line)) { return }

    if (-not [string]::IsNullOrWhiteSpace($script:LogPath)) {
        try { Add-Content -Path $script:LogPath -Value "    $Line" -Encoding UTF8 } catch { }
    }

    if ($null -eq $script:LogBox) { return }
    $script:LogBox.SelectionStart = $script:LogBox.TextLength
    $script:LogBox.SelectionColor = $Theme.TextMuted
    $script:LogBox.AppendText("      $Line`r`n")
    $script:LogBox.SelectionStart = $script:LogBox.TextLength
    $script:LogBox.ScrollToCaret()
    [System.Windows.Forms.Application]::DoEvents()
}

# Atualiza o texto de status atual.
function Set-Status {
    param([string]$Text)
    if ($null -ne $script:StatusLabel) {
        $script:StatusLabel.Text = $Text
        [System.Windows.Forms.Application]::DoEvents()
    }
}


# =============================================================================
# REGIAO 3 - PROGRESSBAR (barra customizada panel-dentro-de-panel)
# =============================================================================
function Set-Progress {
    param([int]$Percent)

    $script:ProgressPct = [Math]::Max(0, [Math]::Min(100, $Percent))
    if ($null -ne $script:ProgressTrack -and $null -ne $script:ProgressFill) {
        $w = [int]($script:ProgressTrack.ClientSize.Width * ($script:ProgressPct / 100.0))
        $script:ProgressFill.Width = $w
    }
    [System.Windows.Forms.Application]::DoEvents()
}


# =============================================================================
# REGIAO 4 - CANCELAMENTO (CancellationTokenSource)
# =============================================================================

# Lanca uma excecao especifica se o cancelamento foi solicitado. Chamada antes
# de cada etapa para interromper o fluxo de forma segura.
function Test-Cancellation {
    if ($null -ne $script:Cts -and $script:Cts.IsCancellationRequested) {
        throw [System.OperationCanceledException]::new('Operacao cancelada pelo usuario.')
    }
}


# =============================================================================
# REGIAO 5 - EXECUCAO (helpers de processo + cada etapa de manutencao)
# =============================================================================

# Executa um programa externo (cmd interno, sfc, dism, chkdsk, etc.) de forma
# NAO bloqueante: lanca o processo com saida redirecionada e, num laco de
# polling, drena a saida para o log e chama DoEvents() (UI nunca trava).
# Verifica o token de cancelamento e, se acionado, mata a arvore de processos.
function Invoke-ExternalProcess {
    param(
        [string]$FilePath,
        [string]$Arguments
    )

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName               = $FilePath
    $psi.Arguments              = $Arguments
    $psi.UseShellExecute        = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.CreateNoWindow         = $true
    $psi.StandardOutputEncoding = [System.Text.Encoding]::Default
    $psi.StandardErrorEncoding  = [System.Text.Encoding]::Default

    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi

    # Fila thread-safe: os eventos de saida disparam em threads de fundo, entao
    # apenas enfileiramos; a UI e tocada somente na thread principal (no laco).
    $queue = [System.Collections.Concurrent.ConcurrentQueue[string]]::new()
    $sink  = {
        if (-not [string]::IsNullOrEmpty($EventArgs.Data)) {
            $Event.MessageData.Enqueue($EventArgs.Data)
        }
    }
    $outEvt = Register-ObjectEvent -InputObject $proc -EventName OutputDataReceived -Action $sink -MessageData $queue
    $errEvt = Register-ObjectEvent -InputObject $proc -EventName ErrorDataReceived  -Action $sink -MessageData $queue

    try {
        [void]$proc.Start()
        $proc.BeginOutputReadLine()
        $proc.BeginErrorReadLine()

        while (-not $proc.HasExited) {
            # Drena a saida acumulada para o log.
            $line = ''
            while ($queue.TryDequeue([ref]$line)) { Write-RawLine $line }

            # Cancelamento: mata a arvore de processos com taskkill.
            if ($null -ne $script:Cts -and $script:Cts.IsCancellationRequested) {
                try { & taskkill.exe /PID $proc.Id /T /F 2>$null | Out-Null } catch { }
                try { $proc.WaitForExit(3000) | Out-Null } catch { }
                throw [System.OperationCanceledException]::new('Operacao cancelada pelo usuario.')
            }

            Start-Sleep -Milliseconds 120
            [System.Windows.Forms.Application]::DoEvents()
        }

        # Drena o restante apos o termino.
        Start-Sleep -Milliseconds 150
        $line = ''
        while ($queue.TryDequeue([ref]$line)) { Write-RawLine $line }

        return $proc.ExitCode
    }
    finally {
        Unregister-Event -SourceIdentifier $outEvt.Name -ErrorAction SilentlyContinue
        Unregister-Event -SourceIdentifier $errEvt.Name -ErrorAction SilentlyContinue
        $proc.Dispose()
    }
}

# Remove com seguranca o conteudo de uma pasta (arquivos + subpastas), sem
# falhar quando algum item esta em uso. Retorna a contagem de itens removidos.
function Clear-FolderContents {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        Write-Log "Pasta nao encontrada: $Path" 'WARN'
        return
    }

    $removed = 0
    $errors  = 0
    Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue | ForEach-Object {
        Test-Cancellation
        try {
            Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction Stop
            $removed++
        }
        catch {
            $errors++
        }
    }
    Write-Log "Itens removidos: $removed (ignorados/em uso: $errors)" 'OK'
}

# --- Informacoes do sistema --------------------------------------------------
function Show-WindowsVersion {
    try {
        $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
        Write-Log "Windows: $($os.Caption) (Build $($os.BuildNumber))" 'INFO'
    }
    catch {
        Write-Log "Windows: $([Environment]::OSVersion.VersionString)" 'INFO'
    }
}

function Show-Volumes {
    param([string]$Titulo)
    Write-Log $Titulo 'STEP'
    try {
        Get-Volume -ErrorAction Stop |
            Where-Object { $_.DriveLetter } |
            Sort-Object DriveLetter |
            ForEach-Object {
                $livre = [math]::Round($_.SizeRemaining / 1GB, 2)
                $total = [math]::Round($_.Size / 1GB, 2)
                Write-RawLine ("Unidade {0}:  Livre {1} GB / Total {2} GB" -f $_.DriveLetter, $livre, $total)
            }
    }
    catch {
        Write-Log "Nao foi possivel ler os volumes: $($_.Exception.Message)" 'WARN'
    }
}

function Show-PhysicalDisks {
    Write-Log "Saude dos discos fisicos (Get-PhysicalDisk)" 'STEP'
    try {
        Get-PhysicalDisk -ErrorAction Stop | ForEach-Object {
            Write-RawLine ("{0}  |  Saude: {1}  |  Estado: {2}" -f `
                $_.FriendlyName, $_.HealthStatus, $_.OperationalStatus)
        }
    }
    catch {
        Write-Log "Nao foi possivel ler os discos fisicos: $($_.Exception.Message)" 'WARN'
    }
}


# =============================================================================
# REGIAO 6 - ORQUESTRACAO (fluxo completo da manutencao)
# =============================================================================
function Invoke-Maintenance {
    $inicio = Get-Date
    $cancelado = $false

    try {
        Set-Progress 0

        # --- Cabecalho / informacoes iniciais -------------------------------
        Write-Log "==========================================" 'INFO'
        Write-Log "INICIO DA MANUTENCAO" 'STEP'
        Write-Log "Data/Hora: $($inicio.ToString('dd/MM/yyyy HH:mm:ss'))" 'INFO'
        Write-Log "==========================================" 'INFO'
        Show-WindowsVersion
        Show-Volumes "Espaco disponivel ANTES da limpeza"

        # 10 etapas -> ~9 pontos de progresso por etapa.
        # --- Etapa 1: cache DNS ---------------------------------------------
        Test-Cancellation
        Set-Status 'Etapa 1/10 - Limpando cache DNS...'
        Write-Log "[1/10] Limpando cache DNS..." 'STEP'
        Invoke-ExternalProcess -FilePath 'ipconfig.exe' -Arguments '/flushdns' | Out-Null
        Write-Log "Cache DNS limpo." 'OK'
        Set-Progress 10

        # --- Etapa 2: %TEMP% ------------------------------------------------
        Test-Cancellation
        Set-Status 'Etapa 2/10 - Limpando temporarios do usuario (%TEMP%)...'
        Write-Log "[2/10] Limpando temporarios do usuario: $env:TEMP" 'STEP'
        Clear-FolderContents -Path $env:TEMP
        Set-Progress 20

        # --- Etapa 3: C:\Windows\Temp ---------------------------------------
        Test-Cancellation
        Set-Status 'Etapa 3/10 - Limpando C:\Windows\Temp...'
        Write-Log "[3/10] Limpando C:\Windows\Temp" 'STEP'
        Clear-FolderContents -Path 'C:\Windows\Temp'
        Set-Progress 30

        # --- Etapa 4: SoftwareDistribution\Download -------------------------
        Test-Cancellation
        Set-Status 'Etapa 4/10 - Limpando cache do Windows Update...'
        Write-Log "[4/10] Limpando cache do Windows Update..." 'STEP'
        Write-Log "Parando servicos wuauserv e bits..." 'INFO'
        Invoke-ExternalProcess -FilePath 'net.exe' -Arguments 'stop wuauserv' | Out-Null
        Invoke-ExternalProcess -FilePath 'net.exe' -Arguments 'stop bits'     | Out-Null
        Clear-FolderContents -Path 'C:\Windows\SoftwareDistribution\Download'
        Write-Log "Reiniciando servicos bits e wuauserv..." 'INFO'
        Invoke-ExternalProcess -FilePath 'net.exe' -Arguments 'start bits'     | Out-Null
        Invoke-ExternalProcess -FilePath 'net.exe' -Arguments 'start wuauserv' | Out-Null
        Write-Log "Cache do Windows Update limpo." 'OK'
        Set-Progress 40

        # --- Etapa 5: SFC /SCANNOW ------------------------------------------
        Test-Cancellation
        Set-Status 'Etapa 5/10 - Verificando integridade (SFC /SCANNOW)... pode demorar.'
        Write-Log "[5/10] SFC /SCANNOW - verificando integridade do Windows..." 'STEP'
        $code = Invoke-ExternalProcess -FilePath 'sfc.exe' -Arguments '/scannow'
        Write-Log "SFC concluido (codigo $code)." 'OK'
        Set-Progress 55

        # --- Etapa 6: DISM RestoreHealth ------------------------------------
        Test-Cancellation
        Set-Status 'Etapa 6/10 - Reparando imagem (DISM /RestoreHealth)... pode demorar.'
        Write-Log "[6/10] DISM /Online /Cleanup-Image /RestoreHealth..." 'STEP'
        $code = Invoke-ExternalProcess -FilePath 'dism.exe' -Arguments '/Online /Cleanup-Image /RestoreHealth'
        Write-Log "DISM RestoreHealth concluido (codigo $code)." 'OK'
        Set-Progress 70

        # --- Etapa 7: CHKDSK C: /scan ---------------------------------------
        Test-Cancellation
        Set-Status 'Etapa 7/10 - Verificando disco (CHKDSK C: /scan)...'
        Write-Log "[7/10] CHKDSK C: /scan..." 'STEP'
        $code = Invoke-ExternalProcess -FilePath 'chkdsk.exe' -Arguments 'C: /scan'
        Write-Log "CHKDSK concluido (codigo $code)." 'OK'
        Set-Progress 82

        # --- Etapa 8: DISM StartComponentCleanup ----------------------------
        Test-Cancellation
        Set-Status 'Etapa 8/10 - Limpando componentes antigos (DISM)...'
        Write-Log "[8/10] DISM /Online /Cleanup-Image /StartComponentCleanup..." 'STEP'
        $code = Invoke-ExternalProcess -FilePath 'dism.exe' -Arguments '/Online /Cleanup-Image /StartComponentCleanup'
        Write-Log "DISM StartComponentCleanup concluido (codigo $code)." 'OK'
        Set-Progress 90

        # --- Etapa 9: saude dos discos --------------------------------------
        Test-Cancellation
        Set-Status 'Etapa 9/10 - Lendo saude dos discos...'
        Write-Log "[9/10] Saude dos discos" 'STEP'
        Show-PhysicalDisks
        Set-Progress 95

        # --- Etapa 10: espaco livre apos limpeza ----------------------------
        Test-Cancellation
        Set-Status 'Etapa 10/10 - Lendo espaco livre atualizado...'
        Write-Log "[10/10] Espaco livre apos limpeza" 'STEP'
        Show-Volumes "Espaco disponivel APOS a limpeza"
        Set-Progress 100

        # --- Resumo final ---------------------------------------------------
        $fim      = Get-Date
        $duracao  = $fim - $inicio
        $durTexto = "{0:00}:{1:00}:{2:00}" -f $duracao.Hours, $duracao.Minutes, $duracao.Seconds

        Write-Log "==========================================" 'INFO'
        Write-Log "FIM DA MANUTENCAO" 'OK'
        Write-Log "Inicio .....: $($inicio.ToString('dd/MM/yyyy HH:mm:ss'))" 'INFO'
        Write-Log "Termino ....: $($fim.ToString('dd/MM/yyyy HH:mm:ss'))" 'INFO'
        Write-Log "Duracao ....: $durTexto" 'INFO'
        Write-Log "Log salvo em: $($script:LogPath)" 'INFO'
        Write-Log "==========================================" 'INFO'
        Set-Status "Concluido em $durTexto"

        return [pscustomobject]@{ Cancelado = $false; Duracao = $durTexto }
    }
    catch [System.OperationCanceledException] {
        $cancelado = $true
        Write-Log "Manutencao CANCELADA pelo usuario." 'WARN'
        Set-Status 'Cancelado.'
        return [pscustomobject]@{ Cancelado = $true; Duracao = $null }
    }
    catch {
        Write-Log "Erro durante a manutencao: $($_.Exception.Message)" 'ERROR'
        Set-Status 'Erro durante a execucao.'
        [System.Windows.Forms.MessageBox]::Show(
            "Ocorreu um erro durante a manutencao:`r`n`r`n$($_.Exception.Message)",
            'Erro', 'OK', 'Error') | Out-Null
        return [pscustomobject]@{ Cancelado = $false; Duracao = $null; Erro = $true }
    }
}


# =============================================================================
# REGIAO 7 - UI (Windows Forms)
# =============================================================================

# --- Helpers de criacao de controles estilizados (DRY) ----------------------
function New-Label {
    param([string]$Text, [int]$X, [int]$Y, [int]$Width = 320, [bool]$Muted = $false)
    $l = New-Object System.Windows.Forms.Label
    $l.Text      = $Text
    $l.Location  = New-Object System.Drawing.Point($X, $Y)
    $l.Size      = New-Object System.Drawing.Size($Width, 20)
    $l.ForeColor = if ($Muted) { $Theme.TextMuted } else { $Theme.Text }
    $l.BackColor = [System.Drawing.Color]::Transparent
    $l.Font      = New-Object System.Drawing.Font($FontFamily, 9.5)
    return $l
}

# Botao "flat" moderno com cantos arredondados e efeito hover.
function New-Button {
    param(
        [string]$Text, [int]$X, [int]$Y, [int]$Width,
        [System.Drawing.Color]$BackColor, [System.Drawing.Color]$ForeColor
    )
    $b = New-Object System.Windows.Forms.Button
    $b.Text      = $Text
    $b.Location  = New-Object System.Drawing.Point($X, $Y)
    $b.Size      = New-Object System.Drawing.Size($Width, 40)
    $b.FlatStyle = 'Flat'
    $b.BackColor = $BackColor
    $b.ForeColor = $ForeColor
    $b.Font      = New-Object System.Drawing.Font($FontFamily, 10, [System.Drawing.FontStyle]::Bold)
    $b.Cursor    = [System.Windows.Forms.Cursors]::Hand
    $b.FlatAppearance.BorderSize = 0

    # Cantos arredondados via Region (GraphicsPath).
    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    $d = 16
    $path.AddArc(0, 0, $d, $d, 180, 90)
    $path.AddArc($b.Width - $d, 0, $d, $d, 270, 90)
    $path.AddArc($b.Width - $d, $b.Height - $d, $d, $d, 0, 90)
    $path.AddArc(0, $b.Height - $d, $d, $d, 90, 90)
    $path.CloseFigure()
    $b.Region = New-Object System.Drawing.Region($path)

    # Hover (escurece levemente).
    $baseColor  = $BackColor
    $hoverColor = [System.Drawing.Color]::FromArgb(
        [Math]::Max(0, $baseColor.R - 20),
        [Math]::Max(0, $baseColor.G - 20),
        [Math]::Max(0, $baseColor.B - 20))
    $b.Add_MouseEnter({ if ($this.Enabled) { $this.BackColor = $hoverColor } }.GetNewClosure())
    $b.Add_MouseLeave({ if ($this.Enabled) { $this.BackColor = $baseColor  } }.GetNewClosure())
    return $b
}

# --- Janela principal --------------------------------------------------------
$form = New-Object System.Windows.Forms.Form
$form.Text          = 'Manutencao Completa do Windows'
$form.Size          = New-Object System.Drawing.Size(820, 720)
$form.MinimumSize   = New-Object System.Drawing.Size(820, 720)
$form.StartPosition = 'CenterScreen'
$form.BackColor     = $Theme.Background
$form.Font          = New-Object System.Drawing.Font($FontFamily, 9.5)
$form.ForeColor     = $Theme.Text

# --- Cabecalho ---------------------------------------------------------------
$header = New-Object System.Windows.Forms.Panel
$header.Location  = New-Object System.Drawing.Point(0, 0)
$header.Size      = New-Object System.Drawing.Size(820, 72)
$header.BackColor = $Theme.SurfaceAlt
$header.Anchor    = 'Top,Left,Right'
$form.Controls.Add($header)

$title = New-Object System.Windows.Forms.Label
$title.Text      = [System.Char]::ConvertFromUtf32(0x1F6E0) + '  Manutencao Completa do Windows'
$title.Location  = New-Object System.Drawing.Point(20, 12)
$title.Size      = New-Object System.Drawing.Size(780, 28)
$title.ForeColor = $Theme.Text
$title.BackColor = [System.Drawing.Color]::Transparent
$title.Font      = New-Object System.Drawing.Font($FontFamily, 15, [System.Drawing.FontStyle]::Bold)
$header.Controls.Add($title)

$subtitle = New-Object System.Windows.Forms.Label
$subtitle.Text      = 'DNS - Temporarios - Windows Update - SFC - DISM - CHKDSK - Saude dos discos'
$subtitle.Location  = New-Object System.Drawing.Point(22, 44)
$subtitle.Size      = New-Object System.Drawing.Size(780, 20)
$subtitle.ForeColor = $Theme.TextMuted
$subtitle.BackColor = [System.Drawing.Color]::Transparent
$subtitle.Font      = New-Object System.Drawing.Font($FontFamily, 9)
$header.Controls.Add($subtitle)

$colL = 24

# --- Arquivo de log: label + botao "Selecionar Log" -------------------------
$form.Controls.Add((New-Label -Text 'Arquivo de log' -X $colL -Y 88 -Muted $true))

$lblLogPath = New-Object System.Windows.Forms.Label
$lblLogPath.Text      = $script:LogPath
$lblLogPath.Location  = New-Object System.Drawing.Point($colL, 110)
$lblLogPath.Size      = New-Object System.Drawing.Size(580, 30)
$lblLogPath.ForeColor = $Theme.Text
$lblLogPath.BackColor = $Theme.Surface
$lblLogPath.Padding   = New-Object System.Windows.Forms.Padding(8, 6, 8, 6)
$lblLogPath.AutoEllipsis = $true
$lblLogPath.Font      = New-Object System.Drawing.Font('Consolas', 9)
$lblLogPath.Anchor    = 'Top,Left,Right'
$form.Controls.Add($lblLogPath)

$btnSelLog = New-Button -Text ([System.Char]::ConvertFromUtf32(0x1F4C1) + ' Selecionar Log') -X 620 -Y 108 -Width 170 `
    -BackColor $Theme.Surface -ForeColor $Theme.Text
$btnSelLog.Height = 34
$btnSelLog.Anchor = 'Top,Right'
$form.Controls.Add($btnSelLog)

# --- Botoes de acao ----------------------------------------------------------
$btnStart = New-Button -Text ([System.Char]::ConvertFromUtf32(0x25B6) + ' Iniciar') -X $colL -Y 156 -Width 200 `
    -BackColor $Theme.Accent -ForeColor $Theme.SurfaceAlt
$form.Controls.Add($btnStart)

$btnCancel = New-Button -Text ([System.Char]::ConvertFromUtf32(0x23F9) + ' Cancelar') -X 234 -Y 156 -Width 170 `
    -BackColor $Theme.Danger -ForeColor $Theme.Text
$btnCancel.Enabled = $false
$form.Controls.Add($btnCancel)

$btnClear = New-Button -Text ([System.Char]::ConvertFromUtf32(0x1F9F9) + ' Limpar logs') -X 416 -Y 156 -Width 160 `
    -BackColor $Theme.Surface -ForeColor $Theme.Text
$form.Controls.Add($btnClear)

# --- Status atual ------------------------------------------------------------
$form.Controls.Add((New-Label -Text 'Status' -X $colL -Y 210 -Muted $true))
$script:StatusLabel = New-Object System.Windows.Forms.Label
$script:StatusLabel.Text      = 'Aguardando inicio...'
$script:StatusLabel.Location  = New-Object System.Drawing.Point($colL, 232)
$script:StatusLabel.Size      = New-Object System.Drawing.Size(760, 22)
$script:StatusLabel.ForeColor = $Theme.Accent
$script:StatusLabel.BackColor = [System.Drawing.Color]::Transparent
$script:StatusLabel.Font      = New-Object System.Drawing.Font($FontFamily, 10, [System.Drawing.FontStyle]::Bold)
$script:StatusLabel.Anchor    = 'Top,Left,Right'
$form.Controls.Add($script:StatusLabel)

# --- Barra de progresso customizada -----------------------------------------
$form.Controls.Add((New-Label -Text 'Progresso' -X $colL -Y 262 -Muted $true))

$script:ProgressTrack = New-Object System.Windows.Forms.Panel
$script:ProgressTrack.Location  = New-Object System.Drawing.Point($colL, 284)
$script:ProgressTrack.Size      = New-Object System.Drawing.Size(766, 16)
$script:ProgressTrack.BackColor = $Theme.Surface
$script:ProgressTrack.Anchor    = 'Top,Left,Right'
$form.Controls.Add($script:ProgressTrack)

$script:ProgressFill = New-Object System.Windows.Forms.Panel
$script:ProgressFill.Location  = New-Object System.Drawing.Point(0, 0)
$script:ProgressFill.Size      = New-Object System.Drawing.Size(0, 16)
$script:ProgressFill.BackColor = $Theme.Accent
$script:ProgressTrack.Controls.Add($script:ProgressFill)
$script:ProgressTrack.Add_Resize({
    $script:ProgressFill.Height = $script:ProgressTrack.ClientSize.Height
    Set-Progress $script:ProgressPct
})

# --- Area de logs ------------------------------------------------------------
$form.Controls.Add((New-Label -Text 'Logs' -X $colL -Y 314 -Muted $true))

$script:LogBox = New-Object System.Windows.Forms.RichTextBox
$script:LogBox.Location    = New-Object System.Drawing.Point($colL, 336)
$script:LogBox.Size        = New-Object System.Drawing.Size(766, 330)
$script:LogBox.BackColor   = $Theme.SurfaceAlt
$script:LogBox.ForeColor   = $Theme.Text
$script:LogBox.Font        = New-Object System.Drawing.Font('Consolas', 9.5)
$script:LogBox.ReadOnly    = $true
$script:LogBox.BorderStyle = 'None'
$script:LogBox.Anchor      = 'Top,Bottom,Left,Right'
$form.Controls.Add($script:LogBox)

# --- Eventos -----------------------------------------------------------------

# Selecionar o arquivo de log (SaveFileDialog).
$btnSelLog.Add_Click({
    $dlg = New-Object System.Windows.Forms.SaveFileDialog
    $dlg.Title       = 'Escolha onde salvar o arquivo de log'
    $dlg.Filter      = 'Arquivo de texto (*.txt)|*.txt|Todos os arquivos (*.*)|*.*'
    $dlg.FileName    = [System.IO.Path]::GetFileName($script:LogPath)
    $dlg.InitialDirectory = [System.IO.Path]::GetDirectoryName($script:LogPath)
    if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $script:LogPath = $dlg.FileName
        $lblLogPath.Text = $script:LogPath
        Write-Log "Arquivo de log definido: $($script:LogPath)" 'INFO'
    }
})

# Limpar logs (somente quando ocioso).
$btnClear.Add_Click({
    if ($script:IsRunning) { return }
    $script:LogBox.Clear()
    Set-Progress 0
    Set-Status 'Aguardando inicio...'
})

# Cancelar.
$btnCancel.Add_Click({
    if ($null -ne $script:Cts -and -not $script:Cts.IsCancellationRequested) {
        $script:Cts.Cancel()
        Write-Log "Cancelamento solicitado... aguardando a etapa atual encerrar com seguranca." 'WARN'
        Set-Status 'Cancelando...'
        $btnCancel.Enabled = $false
    }
})

# Iniciar.
$btnStart.Add_Click({
    if ($script:IsRunning) { return }

    if (-not (Test-IsAdministrator)) {
        Write-Log 'Sem privilegios de Administrador. Reabra o aplicativo como administrador.' 'ERROR'
        [System.Windows.Forms.MessageBox]::Show(
            'Execute o aplicativo como Administrador para realizar a manutencao.',
            'Permissao necessaria', 'OK', 'Warning') | Out-Null
        return
    }

    # Confirma o arquivo de log e inicializa-o.
    try {
        $dir = [System.IO.Path]::GetDirectoryName($script:LogPath)
        if (-not [string]::IsNullOrWhiteSpace($dir) -and -not (Test-Path $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
        Set-Content -Path $script:LogPath -Value "=== Manutencao do Windows - $(Get-Date -Format 'dd/MM/yyyy HH:mm:ss') ===" -Encoding UTF8
    }
    catch {
        Write-Log "Nao foi possivel criar o arquivo de log: $($_.Exception.Message)" 'ERROR'
        return
    }

    # Prepara estado de execucao.
    $script:Cts       = New-Object System.Threading.CancellationTokenSource
    $script:IsRunning = $true
    $btnStart.Enabled  = $false
    $btnClear.Enabled  = $false
    $btnSelLog.Enabled = $false
    $btnCancel.Enabled = $true

    try {
        $resultado = Invoke-Maintenance

        if ($resultado.Cancelado) {
            [System.Windows.Forms.MessageBox]::Show(
                'A manutencao foi cancelada.',
                'Cancelado', 'OK', 'Information') | Out-Null
        }
        elseif (-not $resultado.Erro) {
            $msg = "Manutencao concluida com sucesso!`r`n`r`nDuracao total: $($resultado.Duracao)`r`nLog salvo em:`r`n$($script:LogPath)`r`n`r`nDeseja reiniciar o computador agora?"
            $r = [System.Windows.Forms.MessageBox]::Show(
                $msg, 'Manutencao concluida', 'YesNo', 'Question')
            if ($r -eq [System.Windows.Forms.DialogResult]::Yes) {
                Write-Log "Reiniciando o computador (shutdown /r /t 0)..." 'WARN'
                Start-Process -FilePath 'shutdown.exe' -ArgumentList '/r','/t','0' -WindowStyle Hidden
            }
        }
    }
    finally {
        $script:IsRunning = $false
        if ($null -ne $script:Cts) { $script:Cts.Dispose(); $script:Cts = $null }
        $btnStart.Enabled  = $true
        $btnClear.Enabled  = $true
        $btnSelLog.Enabled = $true
        $btnCancel.Enabled = $false
    }
})

# Impede fechar a janela durante a execucao.
$form.Add_FormClosing({
    if ($script:IsRunning) {
        $r = [System.Windows.Forms.MessageBox]::Show(
            'A manutencao esta em andamento. Deseja cancelar e sair?',
            'Manutencao em andamento', 'YesNo', 'Warning')
        if ($r -eq [System.Windows.Forms.DialogResult]::Yes) {
            if ($null -ne $script:Cts) { $script:Cts.Cancel() }
        }
        $_.Cancel = $true
    }
})

# Mensagem inicial amigavel.
$form.Add_Shown({
    Write-Log 'Bem-vindo! Clique em "Iniciar" para executar a manutencao do Windows.' 'INFO'
    Show-WindowsVersion
    if (Test-IsAdministrator) {
        Write-Log 'Executando como Administrador.' 'OK'
    } else {
        Write-Log 'ATENCAO: nao esta como Administrador. Reabra elevado.' 'WARN'
    }
    Write-Log "Log sera salvo em: $($script:LogPath)" 'INFO'
})

# Exibe a janela.
[void]$form.ShowDialog()
