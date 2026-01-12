# Project Map (MQL5)

## Visao geral
- Nome do projeto/indicador: FFT PhaseClock WaveTrader + ColorWave
- Objetivo: Indicador de fase/onda via FFT + EA de trading baseado em slope/turno da onda
- Saidas principais (plots/objetos):
  - Indicador: linha colorida da wave + opcional forecast/clock
  - EA: ordens (duas pernas), SL/TP, BE, trailing

## Arvore de arquivos
- `4EA-IND/IND-FFT_PhaseClock_CLOSE_SINFLIP_LEAD_v1.5_ColorWave.mq5` (indicador monolitico)
- `4EA-EXP/EA_FFT_PhaseClock_WaveTrader.mq5` (EA monolitico)

## Fluxo de dados (pipeline)
1. Feed (OHLC/ATR/volume) ->
2. Windowing (Hann/Sine/Kaiser) ->
3. DSP (FFT + bandpass + analitico/Hilbert) ->
4. Metricas (fase/magnitude/sin/cos + lead) ->
5. Estado (cache/omega/forecast) ->
6. Renderers (linha colorida, forecast, clock)

## Modulos (contratos) — proposta de modularizacao
### Indicador
- `PhaseEngine.mqh`
  - Responsabilidade: feed + FFT + bandpass + analitico + fase/magnitude
  - Inputs: parametros de feed/FFT/bandpass/lead
  - Outputs: fase, amp, wave (sin/cos)
  - API: `Init(config)`, `ComputeBar0(...)`

- `ForecastEngine.mqh`
  - Responsabilidade: zero-phase + forecast (mirror/linreg)
  - Inputs: series + config
  - Outputs: wave atual + valores futuros

- `ClockRenderer.mqh`
  - Responsabilidade: desenhar relogio/labels
  - Inputs: fase atual + config visual

- `WaveRenderer.mqh`
  - Responsabilidade: buffers e cores
  - Inputs: wave atual + slope

### EA
- `SignalEngine.mqh`
  - Responsabilidade: ler indicador, calcular slope/turno/zero-cross
  - Inputs: handle + config de sinal
  - Outputs: sinal (+1/-1/0), direcao/slope

- `ConfirmEngine.mqh`
  - Responsabilidade: confirmacao em TF inferior
  - Inputs: handle confirmacao + config
  - Outputs: ok/nao

- `RiskEngine.mqh`
  - Responsabilidade: sizing (fixo/risco), limites de spread

- `TradeManager.mqh`
  - Responsabilidade: abrir/fechar posicoes, legs, SL/TP

- `ExitManager.mqh`
  - Responsabilidade: BE, trailing, parcial

## Modos e flags importantes
- Indicador: `ZeroPhaseRT`, `LeadBars`, `PhaseOffsetDeg`, `InvertOutput`
- EA: `SignalMode`, `UseClosedBarSignals`, `UseLowerTFConfirm`

## Assumptions
- A logica atual de sinal baseia-se na inclinacao da wave (slope).
- A confirmacao em TF inferior deve ser opcional e nao altera o TF principal.
