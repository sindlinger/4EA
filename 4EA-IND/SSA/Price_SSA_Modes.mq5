#property indicator_separate_window
#property indicator_buffers 4
#property indicator_plots   4

#property indicator_label1  "SSA Trend (Direct)"
#property indicator_type1   DRAW_LINE
#property indicator_color1  clrLime
#property indicator_style1  STYLE_SOLID
#property indicator_width1  2

#property indicator_label2  "SSA Forecast (Direct)"
#property indicator_type2   DRAW_LINE
#property indicator_color2  clrMediumSeaGreen
#property indicator_style2  STYLE_DASHDOTDOT
#property indicator_width2  1

#property indicator_label3  "SSA Trend (Realtime)"
#property indicator_type3   DRAW_LINE
#property indicator_color3  clrOrange
#property indicator_style3  STYLE_SOLID
#property indicator_width3  2

#property indicator_label4  "SSA Forecast (Realtime)"
#property indicator_type4   DRAW_LINE
#property indicator_color4  clrDarkOrange
#property indicator_style4  STYLE_DASHDOTDOT
#property indicator_width4  1

#include <Math\Alglib\alglib.mqh>
#include <Object.mqh>

enum SSAMode
  {
   SSA_MODE_DIRECT   = 0,
   SSA_MODE_REALTIME = 1,
   SSA_MODE_BOTH     = 2
  };

input SSAMode InpMode                = SSA_MODE_BOTH;
input int     InpSSAWindow           = 1024;     // Janela SSA (>=2)
input int     InpSSATopK             = 26;      // Componentes principais (>=1)
input int     InpForecastHorizon     = 13;      // Passos de previsão (>=1)
input bool    InpDrawForecast        = true;   // Plotar previsão no gráfico
input double  InpRealtimeUpdateIts   = 1.0;    // Iterações do solver incremental
input int     InpRealtimePowerUp     = 0;      // Comprimento do power-up (0 = desliga)
input int     InpHistoryDepth        = 4096;   // Máximo de barras consideradas
input bool    InpEnableChartShift     = true;   // Força espaço à direita para previsão
input int     InpChartShiftPercent    = 20;     // Percentual do shift (0..50)

//--- buffers de saída
double gDirectTrendBuffer[];
double gDirectForecastBuffer[];
double gRealtimeTrendBuffer[];
double gRealtimeForecastBuffer[];

//--- estruturas ALGLIB
CSSAModel  gDirectModel;
CSSAModel  gRealtimeModel;
CRowDouble gSequence;
CRowDouble gTrendDirect;
CRowDouble gNoiseDirect;
CRowDouble gTrendRealtime;
CRowDouble gNoiseRealtime;
CRowDouble gForecastDirect;
CRowDouble gForecastRealtime;
CRowDouble gSeedRow;

//+------------------------------------------------------------------+
//| Construir sequência cronológica                                  |
//+------------------------------------------------------------------+
void BuildChronologicalSequence(const double &price[],const int count)
  {
   gSequence.Resize(count);
   for(int i=0;i<count;i++)
     {
      const int idx = count -1 - i;
      gSequence.Set(i,price[idx]);
     }
  }

//+------------------------------------------------------------------+
//| Limpa buffers para evitar restos                                   |
//+------------------------------------------------------------------+
void ClearOutputBuffers(const int size)
  {
   for(int i=0;i<size;i++)
     {
      gDirectTrendBuffer[i]      = EMPTY_VALUE;
      gDirectForecastBuffer[i]   = EMPTY_VALUE;
      gRealtimeTrendBuffer[i]    = EMPTY_VALUE;
      gRealtimeForecastBuffer[i] = EMPTY_VALUE;
     }
  }

void ClearRange(double &buffer[],const int count)
  {
   for(int i=0;i<count;i++)
     {
      buffer[i] = EMPTY_VALUE;
     }
  }

//+------------------------------------------------------------------+
//| Atualiza deslocamentos dos plots                                   |
//+------------------------------------------------------------------+
void UpdatePlotShifts()
  {
   PlotIndexSetInteger(1,PLOT_SHIFT,0);
   PlotIndexSetInteger(3,PLOT_SHIFT,0);
  }

void EnsureChartShift()
  {
   if(!InpEnableChartShift)
      return;
   long chart_id = ChartID();
   int shift = MathMax(0, MathMin(InpChartShiftPercent, 50));
   ChartSetInteger(chart_id, (ENUM_CHART_PROPERTY_INTEGER)CHART_SHIFT, 1);
   ChartSetInteger(chart_id, (ENUM_CHART_PROPERTY_INTEGER)CHART_SHIFT_SIZE, shift);
  }

//+------------------------------------------------------------------+
//| Inicialização                                                    |
//+------------------------------------------------------------------+
int OnInit()
  {
   if(InpSSAWindow < 2)
      return(INIT_PARAMETERS_INCORRECT);
   if(InpSSATopK < 1)
      return(INIT_PARAMETERS_INCORRECT);
   if(InpForecastHorizon < 1)
      return(INIT_PARAMETERS_INCORRECT);
   if(InpRealtimeUpdateIts < 0.0)
      return(INIT_PARAMETERS_INCORRECT);

   SetIndexBuffer(0,gDirectTrendBuffer,INDICATOR_DATA);
   SetIndexBuffer(1,gDirectForecastBuffer,INDICATOR_DATA);
   SetIndexBuffer(2,gRealtimeTrendBuffer,INDICATOR_DATA);
   SetIndexBuffer(3,gRealtimeForecastBuffer,INDICATOR_DATA);

   ArraySetAsSeries(gDirectTrendBuffer,true);
   ArraySetAsSeries(gDirectForecastBuffer,true);
   ArraySetAsSeries(gRealtimeTrendBuffer,true);
   ArraySetAsSeries(gRealtimeForecastBuffer,true);

  IndicatorSetInteger(INDICATOR_DIGITS,_Digits);
  IndicatorSetString(INDICATOR_SHORTNAME,"Price SSA Modes");

  UpdatePlotShifts();
  EnsureChartShift();

  return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
//| Deinitialization                                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   // nothing
  }

//+------------------------------------------------------------------+
//| Sincroniza janela/topK e plots                                     |
//+------------------------------------------------------------------+
void SyncCommonSettings()
  {
   PlotIndexSetInteger(0,PLOT_DRAW_BEGIN,0);
   PlotIndexSetInteger(1,PLOT_DRAW_BEGIN,0);
   PlotIndexSetInteger(2,PLOT_DRAW_BEGIN,0);
   PlotIndexSetInteger(3,PLOT_DRAW_BEGIN,0);
   UpdatePlotShifts();
  }

//+------------------------------------------------------------------+
//| Prepara modelo SSA direto                                          |
//+------------------------------------------------------------------+
bool PrepareDirectModel(const int windowWidth,const int topK,const int usable)
  {
   CSSA::SSACreate(gDirectModel);
   CSSA::SSASetWindow(gDirectModel,windowWidth);
   CSSA::SSASetAlgoTopKDirect(gDirectModel,topK);

   CSSA::SSAClearData(gDirectModel);
   CSSA::SSAAddSequence(gDirectModel,gSequence,usable);

   CSSA::SSAAnalyzeSequence(gDirectModel,gSequence,usable,gTrendDirect,gNoiseDirect);
   return(true);
  }

//+------------------------------------------------------------------+
//| Prepara modelo SSA incremental                                     |
//+------------------------------------------------------------------+
bool PrepareRealtimeModel(const int windowWidth,const int topK,const int usable)
  {
   if(usable <= 0)
      return(false);

   CSSA::SSACreate(gRealtimeModel);
   CSSA::SSASetWindow(gRealtimeModel,windowWidth);
   CSSA::SSASetAlgoTopKRealtime(gRealtimeModel,topK);
   if(InpRealtimePowerUp > 0)
      CSSA::SSASetPowerUpLength(gRealtimeModel,InpRealtimePowerUp);

   CSSA::SSAClearData(gRealtimeModel);

   int seedLen = MathMin(windowWidth,usable);
   gSeedRow.Resize(seedLen);
   for(int i=0;i<seedLen;i++)
      gSeedRow.Set(i,gSequence[i]);

   CSSA::SSAAddSequence(gRealtimeModel,gSeedRow,seedLen);

   for(int i=seedLen;i<usable;i++)
      CSSA::SSAAppendPointAndUpdate(gRealtimeModel,gSequence[i],InpRealtimeUpdateIts);

   CSSA::SSAAnalyzeSequence(gRealtimeModel,gSequence,usable,gTrendRealtime,gNoiseRealtime);
   return(true);
  }

//+------------------------------------------------------------------+
//| Popula buffers com tendência                                      |
//+------------------------------------------------------------------+
void FillTrendBuffer(double &buffer[],const CRowDouble &trend,const int count)
  {
   for(int i=0;i<count;i++)
     {
      buffer[i] = trend[count-1 - i];
     }
  }

void FillForecastDisplay(double &buffer[],CRowDouble &holder,const int plot_index)
  {
   ArrayInitialize(buffer,EMPTY_VALUE);

   if(!InpDrawForecast)
     {
      PlotIndexSetInteger(plot_index,PLOT_SHIFT,0);
      return;
     }

  int horizon = MathMin(InpForecastHorizon,(int)holder.Size());
  PlotIndexSetInteger(plot_index,PLOT_SHIFT,horizon);

  for(int i=0;i<horizon;i++)
      buffer[i] = holder[i];
  }

//+------------------------------------------------------------------+
//| Cálculo principal                                                |
//+------------------------------------------------------------------+
int OnCalculate(const int rates_total,
                const int prev_calculated,
                const int begin,
                const double &price[])
  {
   if(prev_calculated>0 && rates_total==prev_calculated)
      return(prev_calculated);

   if(rates_total <= 0)
      return(prev_calculated);

  const int windowWidth = MathMax(InpSSAWindow,2);
  const int topK        = MathMin(MathMax(InpSSATopK,1),windowWidth);
  int historyDepth      = MathMax(windowWidth,InpHistoryDepth);
  const int usable      = MathMin(rates_total,historyDepth);

  SyncCommonSettings();
  if(prev_calculated==0)
     ClearOutputBuffers(rates_total);

  BuildChronologicalSequence(price,usable);

  bool needDirect   = (InpMode == SSA_MODE_DIRECT || InpMode == SSA_MODE_BOTH);
  bool needRealtime = (InpMode == SSA_MODE_REALTIME || InpMode == SSA_MODE_BOTH);

  if(needDirect && PrepareDirectModel(windowWidth,topK,usable))
    {
     ClearRange(gDirectTrendBuffer,usable);
     FillTrendBuffer(gDirectTrendBuffer,gTrendDirect,usable);

     if(InpDrawForecast)
        CSSA::SSAForecastLast(gDirectModel,InpForecastHorizon,gForecastDirect);
     else
        gForecastDirect.Resize(0);

     FillForecastDisplay(gDirectForecastBuffer,gForecastDirect,1);
    }

  if(needRealtime && PrepareRealtimeModel(windowWidth,topK,usable))
    {
     ClearRange(gRealtimeTrendBuffer,usable);
     FillTrendBuffer(gRealtimeTrendBuffer,gTrendRealtime,usable);

     if(InpDrawForecast)
        CSSA::SSAForecastLast(gRealtimeModel,InpForecastHorizon,gForecastRealtime);
     else
        gForecastRealtime.Resize(0);

     FillForecastDisplay(gRealtimeForecastBuffer,gForecastRealtime,3);
    }

  return(rates_total);
 }

//+------------------------------------------------------------------+
