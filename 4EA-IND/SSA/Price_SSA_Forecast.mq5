#property indicator_separate_window
#property indicator_buffers 2
#property indicator_plots   2

#property indicator_label1  "SSA Forecast (Direct)"
#property indicator_type1   DRAW_LINE
#property indicator_color1  clrDeepSkyBlue
#property indicator_style1  STYLE_SOLID
#property indicator_width1  2

#property indicator_label2  "SSA Forecast (Realtime)"
#property indicator_type2   DRAW_LINE
#property indicator_color2  clrOrangeRed
#property indicator_style2  STYLE_SOLID
#property indicator_width2  2

#include <Math\Alglib\alglib.mqh>

enum SSAForecastMode
  {
   SSA_FORECAST_DIRECT_ONLY   = 0,
   SSA_FORECAST_REALTIME_ONLY = 1,
   SSA_FORECAST_BOTH          = 2
  };

input SSAForecastMode InpMode              = SSA_FORECAST_BOTH;
input int             InpSSAWindow         = 64;      // Janela SSA (>=2)
input int             InpSSATopK           = 8;       // Componentes principais (>=1)
input int             InpForecastHorizon   = 8;       // Número de passos previstos (>=1)
input double          InpRealtimeUpdateIts = 1.0;     // Iterações do solver incremental (>=0)
input int             InpRealtimePowerUp   = 0;       // Comprimento do power-up (0 = desliga)
input bool            InpShowComment       = true;    // Exibir os valores previstos via Comment()
input int             InpHistoryDepth      = 1024;    // Máximo de barras consideradas
input bool            InpEnableChartShift  = true;    // Força espaço à direita para previsão
input int             InpChartShiftPercent = 20;      // Percentual do shift (0..50)

//--- buffers de saída
double gForecastDirectBuffer[];
double gForecastRealtimeBuffer[];

//--- estruturas ALGLIB
CSSAModel  gDirectModel;
CSSAModel  gRealtimeModel;
CRowDouble gSequence;
CRowDouble gSeedRow;
CRowDouble gForecastDirect;
CRowDouble gForecastRealtime;
CRowDouble gTmpTrend;
CRowDouble gTmpNoise;

//--- helpers internos
string FormatForecast(const CRowDouble &arr)
  {
   string result = "[";
   int size = (int)arr.Size();
   for(int i=0;i<size;i++)
     {
      result += DoubleToString(arr[i], _Digits);
      if(i < size-1)
         result += ", ";
     }
   result += "]";
   return(result);
  }

void ClearBuffers(const int bars)
  {
   for(int i=0;i<bars;i++)
     {
      gForecastDirectBuffer[i]   = EMPTY_VALUE;
      gForecastRealtimeBuffer[i] = EMPTY_VALUE;
     }
  }

bool BuildChronologicalSequence(const double &price[],const int start,const int count)
  {
   if(count <= 0)
      return(false);

   gSequence.Resize(count);
   for(int i=0;i<count;i++)
     {
      const int idx = start + count -1 - i; // 0 = barra atual -> último índice
      gSequence.Set(i, price[idx]);
     }
   return(true);
  }

void FillForecastBuffer(double &buffer[],CRowDouble &holder,const int plotIndex,const bool applyShift)
  {
   ArrayInitialize(buffer,EMPTY_VALUE);
  int horizon = MathMin(InpForecastHorizon,(int)holder.Size());
  PlotIndexSetInteger(plotIndex,PLOT_SHIFT, applyShift ? horizon : 0);

  for(int i=0;i<horizon;i++)
      buffer[i] = holder[i];
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

bool PrepareDirectForecast(const int windowWidth,const int topK,const int usable)
  {
   if(usable < windowWidth)
      return(false);

   CSSA::SSACreate(gDirectModel);
   CSSA::SSASetWindow(gDirectModel, windowWidth);
   CSSA::SSASetAlgoTopKDirect(gDirectModel, topK);

   CSSA::SSAClearData(gDirectModel);
   CSSA::SSAAddSequence(gDirectModel, gSequence, usable);

   // força cálculo da base para evitar degenerate forecast
   CSSA::SSAAnalyzeSequence(gDirectModel, gSequence, usable, gTmpTrend, gTmpNoise);

   CSSA::SSAForecastLast(gDirectModel, InpForecastHorizon, gForecastDirect);
   return(gForecastDirect.Size() > 0);
  }

bool PrepareRealtimeForecast(const int windowWidth,const int topK,const int usable)
  {
   if(usable < windowWidth)
      return(false);

   CSSA::SSACreate(gRealtimeModel);
   CSSA::SSASetWindow(gRealtimeModel, windowWidth);
   CSSA::SSASetAlgoTopKRealtime(gRealtimeModel, topK);
   if(InpRealtimePowerUp > 0)
      CSSA::SSASetPowerUpLength(gRealtimeModel, InpRealtimePowerUp);

   CSSA::SSAClearData(gRealtimeModel);

   // inicializa dataset com o primeiro bloco (janela)
   gSeedRow.Resize(windowWidth);
   for(int i=0;i<windowWidth;i++)
      gSeedRow.Set(i, gSequence[i]);
   CSSA::SSAAddSequence(gRealtimeModel, gSeedRow, windowWidth);

   for(int i=windowWidth;i<usable;i++)
      CSSA::SSAAppendPointAndUpdate(gRealtimeModel, gSequence[i], InpRealtimeUpdateIts);

   CSSA::SSAForecastLast(gRealtimeModel, InpForecastHorizon, gForecastRealtime);
   return(gForecastRealtime.Size() > 0);
  }

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

   SetIndexBuffer(0, gForecastDirectBuffer, INDICATOR_DATA);
   SetIndexBuffer(1, gForecastRealtimeBuffer, INDICATOR_DATA);

   ArraySetAsSeries(gForecastDirectBuffer, true);
   ArraySetAsSeries(gForecastRealtimeBuffer, true);

   IndicatorSetInteger(INDICATOR_DIGITS, _Digits);
   IndicatorSetString(INDICATOR_SHORTNAME, "Price SSA Forecast");

   PlotIndexSetInteger(0, PLOT_SHIFT, 0);
   PlotIndexSetInteger(1, PLOT_SHIFT, 0);
   EnsureChartShift();

   return(INIT_SUCCEEDED);
  }

int OnCalculate(const int rates_total,
                const int prev_calculated,
                const int begin,
                const double &price[])
  {
   if(prev_calculated>0 && rates_total==prev_calculated)
      return(prev_calculated);

   if(rates_total <= 0)
      return(prev_calculated);

   const int windowWidth = MathMax(InpSSAWindow, 2);
   const int topK        = MathMin(MathMax(InpSSATopK, 1), windowWidth);
   int historyDepth      = MathMax(windowWidth, InpHistoryDepth);
   const int usable      = MathMin(rates_total, historyDepth);
   const int start       = rates_total - usable;

   PlotIndexSetInteger(0, PLOT_DRAW_BEGIN, 0);
   PlotIndexSetInteger(1, PLOT_DRAW_BEGIN, 0);

   if(prev_calculated==0)
      ClearBuffers(rates_total);
   else
     {
      ArrayInitialize(gForecastDirectBuffer,EMPTY_VALUE);
      ArrayInitialize(gForecastRealtimeBuffer,EMPTY_VALUE);
     }

   if(!BuildChronologicalSequence(price, start, usable))
      return(rates_total);

  bool needDirect   = (InpMode == SSA_FORECAST_DIRECT_ONLY || InpMode == SSA_FORECAST_BOTH);
  bool needRealtime = (InpMode == SSA_FORECAST_REALTIME_ONLY || InpMode == SSA_FORECAST_BOTH);

  string commentText = "";

  if(needDirect && PrepareDirectForecast(windowWidth, topK, usable))
    {
      FillForecastBuffer(gForecastDirectBuffer, gForecastDirect, 0, true);
      if(InpShowComment)
         commentText += StringFormat("Direct forecast: %s\n", FormatForecast(gForecastDirect));
    }

  if(needRealtime && PrepareRealtimeForecast(windowWidth, topK, usable))
    {
      FillForecastBuffer(gForecastRealtimeBuffer, gForecastRealtime, 1, false);
      if(InpShowComment)
         commentText += StringFormat("Realtime forecast: %s\n", FormatForecast(gForecastRealtime));
    }

   if(InpShowComment)
     {
      if(commentText == "")
         Comment("SSA Forecast: insufficient data (window length)");
      else
         Comment(commentText);
     }

   return(rates_total);
  }

void OnDeinit(const int reason)
  {
   if(InpShowComment)
      Comment("");
  }

//+------------------------------------------------------------------+
