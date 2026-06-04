# Manutenção Windows

## Descrição

O script `ManutencaoWindows.ps1` foi desenvolvido para automatizar tarefas de manutenção do Windows, permitindo a execução de procedimentos comuns de limpeza e diagnóstico de forma centralizada, com geração de log e possibilidade de interrupção durante a execução.

O objetivo é facilitar a manutenção preventiva do sistema operacional, reduzindo a necessidade de execução manual de diversos comandos administrativos.

---

## Recursos

- Interface gráfica moderna
- Tema Dark
- Logs em tempo real
- Barra de progresso
- Cancelamento seguro
- Auto-elevação UAC
- Limpeza de DNS
- Limpeza de temporários
- Limpeza do Windows Update
- SFC /SCANNOW
- DISM RestoreHealth
- CHKDSK Scan
- Verificação de saúde dos discos
- Relatório em arquivo TXT

---

## Requisitos

- Windows 10 ou superior
- PowerShell 5.1 ou superior
- Executar como Administrador

---

## Como Executar

Abra o PowerShell como Administrador e execute:

```powershell
powershell -ExecutionPolicy Bypass -STA -File "ManutencaoWindows.ps1"
```

---

## Funcionalidades

O script realiza automaticamente:

- Limpeza de cache DNS
- Limpeza de arquivos temporários do usuário
- Limpeza de arquivos temporários do Windows
- Limpeza de cache do Windows Update
- Verificação de integridade do sistema (SFC)
- Verificação e reparo da imagem do Windows (DISM)
- Limpeza de componentes antigos do Windows
- Limpeza da lixeira
- Registro completo das operações em arquivo de log
- Escolha do local para salvar o log
- Barra de progresso durante a execução
- Possibilidade de cancelamento da manutenção

---

## Log de Execução

Ao iniciar o script será solicitado o local para salvar o arquivo de log.

O log contém:

- Data e hora da execução
- Etapas executadas
- Resultados dos comandos
- Possíveis erros encontrados
- Status final da manutenção

Exemplo:

```text
2026-06-04 15:10:22 - Iniciando manutenção

[OK] Cache DNS limpo
[OK] Arquivos temporários removidos
[OK] SFC concluído
[OK] DISM concluído

Manutenção finalizada com sucesso
```

---

## Cancelamento

Durante a execução é possível interromper o processo utilizando o botão de cancelamento disponibilizado na interface.

Ao cancelar:

- A execução é interrompida de forma segura
- O log é finalizado corretamente
- As etapas já concluídas permanecem registradas

---

## Observações

- Algumas etapas podem levar vários minutos dependendo da máquina.
- O comando `SFC` e o `DISM` costumam ser as etapas mais demoradas.
- Recomenda-se executar a manutenção periodicamente, principalmente em máquinas utilizadas diariamente.
- O script não realiza alterações destrutivas no sistema.

---

## Exemplo de Uso

```powershell
powershell -ExecutionPolicy Bypass -STA -File "ManutencaoWindows.ps1"
```

### Frequência Recomendada

- Uso doméstico: mensal
- Ambiente corporativo: quinzenal ou mensal
- Servidores: conforme política de manutenção da empresa

---

## Estrutura do Projeto

```text
ManutencaoWindows/
│
├── ManutencaoWindows.ps1
├── README.md
└── Logs/
```

---

## Autor

Desenvolvido para automatizar e simplificar rotinas de manutenção preventiva do Windows.