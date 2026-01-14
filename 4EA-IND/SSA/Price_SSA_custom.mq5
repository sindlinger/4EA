#property indicator_separate_window
#property indicator_buffers 3
#property indicator_plots   3

#property indicator_label1  "SSA Trend"
#property indicator_type1   DRAW_LINE
#property indicator_color1  clrLime
#property indicator_style1  STYLE_SOLID
#property indicator_width1  2

#property indicator_label2  "SSA Residual"
#property indicator_type2   DRAW_LINE
#property indicator_color2  clrDarkOrange
#property indicator_style2  STYLE_DOT
#property indicator_width2  1

#property indicator_label3  "SSA ZeroPhase (bar0)"
#property indicator_type3   DRAW_ARROW
#property indicator_color3  clrRed
#property indicator_style3  STYLE_SOLID
#property indicator_width3  2

#include <Math\Alglib\alglib.mqh>

enum ZeroPhaseForecastModel
  {
   ZP_FORECAST_SSA    = 0,
   ZP_FORECAST_LINEAR = 1
  };

enum ZeroPhaseMode
  {
   ZP_MODE_OFF = 0,
   ZP_MODE_BAR0_FORECAST = 1,
   ZP_MODE_CENTERED_WINDOW = 2
  };

enum ZeroPhaseTailMode
  {
   ZP_TAIL_NONE = 0,
   ZP_TAIL_FORECAST = 1,
   ZP_TAIL_ONLY_FORECAST = 2
  };

input int  InpSSAWindow      = 64;   // Largura da janela SSA (>= 2)
input int  InpSSATopK        = 4;    // Componentes principais (>= 1)
input bool InpUseRealtimeAlg = false;// Usar algoritmo incremental (Top-K realtime)
input int  InpHistoryDepth   = 1024; // Máximo de barras consideradas
input bool InpShowResidual         = false; // Exibir residual no plot
input bool InpZeroPhaseCurrent      = false; // Janela centrada no candle 0 (sem repintar historico)
input ZeroPhaseMode InpZeroPhaseMode = ZP_MODE_OFF; // Modo de fase zero
input ZeroPhaseTailMode InpZeroPhaseTailMode = ZP_TAIL_NONE; // Preenche cauda com forecast
input int  InpZeroPhaseHalfWindow   = 0;    // 0 = auto (InpSSAWindow/2)
input ZeroPhaseForecastModel InpZeroPhaseForecastModel = ZP_FORECAST_SSA; // Modelo para barras futuras
input int  InpZeroPhaseLinearLookback = 32; // Lookback para forecast linear
input bool InpZeroPhaseOverwriteTrend = false; // Sobrescreve trend no candle 0 (nao canonico)
input bool InpDebugTimes            = true; // Depuracao de datas/horas (barra 0 e ultima)

//--- buffers do indicador
double gTrendBuffer[];
double gResidualBuffer[];
double gZeroPhaseBuffer[];

//--- estruturas ALGLIB
CSSAModel  gSSAModel;
CSSAModel  gForecastModel;
CRowDouble gSequence;
CRowDouble gTrend;
CRowDouble gNoise;
CRowDouble gForecast;
CRowDouble gCenteredSequence;
CRowDouble gCenteredTrend;
CRowDouble gCenteredNoise;
CRowDouble gTmpTrend;
CRowDouble gTmpNoise;

//+------------------------------------------------------------------+
//| Inicialização                                                    |
//+------------------------------------------------------------------+
int OnInit()
  {
   if(InpSSAWindow < 2)
      return(INIT_PARAMETERS_INCORRECT);
   if(InpSSATopK < 1)
      return(INIT_PARAMETERS_INCORRECT);

   SetIndexBuffer(0,gTrendBuffer,INDICATOR_DATA);
   SetIndexBuffer(1,gResidualBuffer,INDICATOR_DATA);
   SetIndexBuffer(2,gZeroPhaseBuffer,INDICATOR_DATA);

   ArraySetAsSeries(gTrendBuffer,true);
   ArraySetAsSeries(gResidualBuffer,true);
   ArraySetAsSeries(gZeroPhaseBuffer,true);

   PlotIndexSetInteger(0,PLOT_DRAW_BEGIN,0);
   PlotIndexSetInteger(1,PLOT_DRAW_BEGIN,0);
   PlotIndexSetInteger(2,PLOT_DRAW_BEGIN,0);
   PlotIndexSetInteger(1,PLOT_DRAW_TYPE, InpShowResidual ? DRAW_LINE : DRAW_NONE);
   PlotIndexSetInteger(1,PLOT_SHOW_DATA, InpShowResidual);
   PlotIndexSetInteger(2,PLOT_DRAW_TYPE, InpZeroPhaseMode == ZP_MODE_BAR0_FORECAST ? DRAW_ARROW : DRAW_NONE);
   PlotIndexSetInteger(2,PLOT_ARROW,159);

   IndicatorSetInteger(INDICATOR_DIGITS,_Digits);
   IndicatorSetString(INDICATOR_SHORTNAME,"Price SSA Trend");

   CSSA::SSACreate(gSSAModel);
   CSSA::SSACreate(gForecastModel);
   CSSA::SSASetWindow(gSSAModel,InpSSAWindow);

   const int topK = MathMin(MathMax(InpSSATopK,1),InpSSAWindow);
   if(InpUseRealtimeAlg)
      CSSA::SSASetAlgoTopKRealtime(gSSAModel,topK);
   else
      CSSA::SSASetAlgoTopKDirect(gSSAModel,topK);

   gSequence.Resize(0);
   gTrend.Resize(0);
   gNoise.Resize(0);

   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
//| Limpeza                                                           |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   if(InpDebugTimes)
      Comment("");
  }

//+------------------------------------------------------------------+
//| Prepara sequência cronológica                                    |
//+------------------------------------------------------------------+
void BuildChronologicalSequence(const double &price[],const int rates_total,const int count,const bool is_series)
  {
   gSequence.Resize(count);
   if(is_series)
     {
      for(int i=0; i<count; ++i)
        {
         const int idx = count - 1 - i;
         gSequence.Set(i,price[idx]);
        }
     }
   else
     {
      const int start = rates_total - count;
      for(int i=0; i<count; ++i)
         gSequence.Set(i, price[start + i]);
     }
  }

int ResolveZeroPhaseHalfWindow(const int windowWidth)
  {
   int half = InpZeroPhaseHalfWindow;
   if(half <= 0)
      half = windowWidth / 2;
   return(MathMax(1, half));
  }

int EffectiveTopK(const int windowWidth)
  {
   return(MathMin(MathMax(InpSSATopK,1), windowWidth));
  }

bool BuildSSAForecast(const int half)
  {
   if(half <= 0)
      return(false);
   int windowWidth = MathMax(InpSSAWindow,2);
   int topK = EffectiveTopK(windowWidth);

   CSSA::SSASetWindow(gForecastModel, windowWidth);
   if(InpUseRealtimeAlg)
      CSSA::SSASetAlgoTopKRealtime(gForecastModel, topK);
   else
      CSSA::SSASetAlgoTopKDirect(gForecastModel, topK);

   CSSA::SSAClearData(gForecastModel);
   int seqSize = (int)gSequence.Size();
   if(seqSize <= 0)
      return(false);
   CSSA::SSAAddSequence(gForecastModel, gSequence, seqSize);

   // força cálculo da base para evitar degenerate forecast
   CSSA::SSAAnalyzeSequence(gForecastModel, gSequence, seqSize, gTmpTrend, gTmpNoise);
   CSSA::SSAForecastLast(gForecastModel, half, gForecast);
   return(gForecast.Size() >= half);
  }

bool BuildLinearForecast(const int usable,const int half)
  {
   if(half <= 0 || usable < 2)
      return(false);

   int lookback = MathMax(2, InpZeroPhaseLinearLookback);
   if(lookback > usable)
      lookback = usable;
   if(lookback < 2)
      return(false);

   double sumX = 0.0, sumY = 0.0, sumXX = 0.0, sumXY = 0.0;
   for(int i=0;i<lookback;i++)
     {
      double y = gSequence[usable - lookback + i];
      sumX  += i;
      sumY  += y;
      sumXX += i * i;
      sumXY += i * y;
     }

   double denom = lookback * sumXX - sumX * sumX;
   double slope = (denom == 0.0) ? 0.0 : (lookback * sumXY - sumX * sumY) / denom;
   double intercept = (sumY - slope * sumX) / lookback;

   gForecast.Resize(half);
   for(int i=0;i<half;i++)
     {
      double x = (lookback - 1) + (i + 1);
      gForecast.Set(i, intercept + slope * x);
     }

   return(true);
  }

bool BuildTailForecast(const int usable,const int half)
  {
   if(InpZeroPhaseForecastModel == ZP_FORECAST_SSA)
      return(BuildSSAForecast(half));
   return(BuildLinearForecast(usable, half));
  }

bool ComputeZeroPhaseCurrent(const int windowWidth,const int usable,const double current_price,double &trendOut,double &residualOut)
  {
   int half = ResolveZeroPhaseHalfWindow(windowWidth);
   if(usable < (half + 1) || half <= 0)
      return(false);

   int centerLen = 2 * half + 1;
   int centerWindow = MathMin(windowWidth, centerLen);
   int start = usable - (half + 1);
   if(start < 0)
      return(false);

   // Usa reflexão (mirror) ao invés de forecast para o "futuro":
   // [x_{-half} ... x_{-1}, x_0, x_{-1} ... x_{-half}]
   gCenteredSequence.Resize(centerLen);
   for(int i=0;i<=half;i++)
      gCenteredSequence.Set(i, gSequence[start + i]);
   for(int i=0;i<half;i++)
      gCenteredSequence.Set(half + 1 + i, gSequence[start + (half - 1 - i)]);

   int topK = EffectiveTopK(centerWindow);
   CSSA::SSASetWindow(gSSAModel, centerWindow);
   if(InpUseRealtimeAlg)
      CSSA::SSASetAlgoTopKRealtime(gSSAModel, topK);
   else
      CSSA::SSASetAlgoTopKDirect(gSSAModel, topK);

   CSSA::SSAClearData(gSSAModel);
   CSSA::SSAAddSequence(gSSAModel, gCenteredSequence, centerLen);
   CSSA::SSAAnalyzeSequence(gSSAModel, gCenteredSequence, centerLen, gCenteredTrend, gCenteredNoise);

   if(gCenteredTrend.Size() <= half)
      return(false);

   trendOut = gCenteredTrend[half];
   residualOut = current_price - trendOut;
   return(true);
  }

bool BuildCenteredSequenceForC(const int c,const int half,const int usable,const bool allowForecastTail)
  {
   int centerLen = 2 * half + 1;
   gCenteredSequence.Resize(centerLen);
   for(int j=0;j<centerLen;j++)
     {
      int idx = c - half + j;
      if(idx < 0)
         return(false);
      if(idx <= usable - 1)
        {
         gCenteredSequence.Set(j, gSequence[idx]);
        }
      else
        {
         if(!allowForecastTail)
            return(false);
         int fidx = idx - (usable - 1) - 1;
         if(fidx < 0 || fidx >= (int)gForecast.Size())
            return(false);
         gCenteredSequence.Set(j, gForecast[fidx]);
        }
     }
   return(true);
  }

void ComputeCenteredZeroPhase(const int rates_total,const int usable,const int windowWidth)
  {
   int half = ResolveZeroPhaseHalfWindow(windowWidth);
   int centerLen = 2 * half + 1;
   if(usable < half + 1 || half <= 0)
      return;

   int effectiveWindow = MathMin(windowWidth, centerLen);
   int topK = EffectiveTopK(effectiveWindow);
   CSSA::SSASetWindow(gSSAModel, effectiveWindow);
   if(InpUseRealtimeAlg)
      CSSA::SSASetAlgoTopKRealtime(gSSAModel, topK);
   else
      CSSA::SSASetAlgoTopKDirect(gSSAModel, topK);

   for(int i=0;i<rates_total;i++)
     {
      gTrendBuffer[i] = EMPTY_VALUE;
      gResidualBuffer[i] = EMPTY_VALUE;
      gZeroPhaseBuffer[i] = EMPTY_VALUE;
     }

   int c_real_start = half;
   int c_real_end = usable - 1 - half;

   if(InpZeroPhaseTailMode != ZP_TAIL_ONLY_FORECAST)
     {
      if(c_real_end >= c_real_start)
        {
         for(int c=c_real_start; c<=c_real_end; ++c)
           {
            if(!BuildCenteredSequenceForC(c, half, usable, false))
               continue;
            CSSA::SSAClearData(gSSAModel);
            CSSA::SSAAddSequence(gSSAModel, gCenteredSequence, centerLen);
            CSSA::SSAAnalyzeSequence(gSSAModel, gCenteredSequence, centerLen, gCenteredTrend, gCenteredNoise);
            if(gCenteredTrend.Size() <= half)
               continue;
            double trendVal = gCenteredTrend[half];
            int bar = usable - 1 - c;
            if(bar < 0 || bar >= rates_total)
               continue;
            gTrendBuffer[bar] = trendVal;
            if(InpShowResidual)
               gResidualBuffer[bar] = gSequence[c] - trendVal;
           }
        }
     }

   if(InpZeroPhaseTailMode != ZP_TAIL_NONE)
     {
      if(!BuildTailForecast(usable, half))
         return;
      int c_tail_start = MathMax(half, usable - 1 - half);
      for(int c=c_tail_start; c<=usable-1; ++c)
        {
         if(!BuildCenteredSequenceForC(c, half, usable, true))
            continue;
         CSSA::SSAClearData(gSSAModel);
         CSSA::SSAAddSequence(gSSAModel, gCenteredSequence, centerLen);
         CSSA::SSAAnalyzeSequence(gSSAModel, gCenteredSequence, centerLen, gCenteredTrend, gCenteredNoise);
         if(gCenteredTrend.Size() <= half)
            continue;
         double trendVal = gCenteredTrend[half];
         int bar = usable - 1 - c;
         if(bar < 0 || bar >= rates_total)
            continue;
         gTrendBuffer[bar] = trendVal;
         if(InpShowResidual)
            gResidualBuffer[bar] = gSequence[c] - trendVal;
        }
     }
  }

void DebugTimes(const bool is_series,const datetime &time[],const int rates_total,const double current_price)
  {
   if(!InpDebugTimes || rates_total <= 0)
      return;
   datetime t0 = is_series ? time[0] : time[rates_total - 1];
   datetime tLast = is_series ? time[rates_total - 1] : time[0];
   string s0 = TimeToString(t0, TIME_DATE|TIME_MINUTES|TIME_SECONDS);
   string sL = TimeToString(tLast, TIME_DATE|TIME_MINUTES|TIME_SECONDS);
   string msg = StringFormat("SSA debug | series=%s | bar0=%s | last=%s | price0=%s",
                             is_series ? "true" : "false",
                             s0, sL, DoubleToString(current_price, _Digits));
   if(rates_total > 0)
     {
      msg += StringFormat("\nTrend[0]=%s Residual[0]=%s",
                          DoubleToString(gTrendBuffer[0], _Digits),
                          DoubleToString(gResidualBuffer[0], _Digits));
      int last = rates_total - 1;
      msg += StringFormat(" | Trend[last]=%s Residual[last]=%s",
                          DoubleToString(gTrendBuffer[last], _Digits),
                          DoubleToString(gResidualBuffer[last], _Digits));
     }
   Comment(msg);
  }

//+------------------------------------------------------------------+
//| Sincroniza parâmetros do modelo SSA                              |
//+------------------------------------------------------------------+
void SyncModelParameters()
  {
   const int windowWidth = MathMax(InpSSAWindow,2);
   const int topK        = EffectiveTopK(windowWidth);

   CSSA::SSASetWindow(gSSAModel,windowWidth);

   if(InpUseRealtimeAlg)
      CSSA::SSASetAlgoTopKRealtime(gSSAModel,topK);
   else
      CSSA::SSASetAlgoTopKDirect(gSSAModel,topK);

   PlotIndexSetInteger(0,PLOT_DRAW_BEGIN,0);
   PlotIndexSetInteger(1,PLOT_DRAW_BEGIN,0);
   PlotIndexSetInteger(2,PLOT_DRAW_BEGIN,0);
   PlotIndexSetInteger(1,PLOT_DRAW_TYPE, InpShowResidual ? DRAW_LINE : DRAW_NONE);
   PlotIndexSetInteger(1,PLOT_SHOW_DATA, InpShowResidual);
   PlotIndexSetInteger(2,PLOT_DRAW_TYPE, InpZeroPhaseMode == ZP_MODE_BAR0_FORECAST ? DRAW_ARROW : DRAW_NONE);
   PlotIndexSetInteger(2,PLOT_ARROW,159);
  }

//+------------------------------------------------------------------+
//| Cálculo principal                                                |
//+------------------------------------------------------------------+
int OnCalculate(const int rates_total,
                const int prev_calculated,
                const datetime &time[],
                const double &open[],
                const double &high[],
                const double &low[],
                const double &close[],
                const long &tick_volume[],
                const long &volume[],
                const int &spread[])
  {
   static datetime s_last_time0 = 0;

  if(rates_total <= 0)
      return(prev_calculated);

  SyncModelParameters();

   const int windowWidth = MathMax(InpSSAWindow,2);
   int historyDepth = MathMax(windowWidth,InpHistoryDepth);
   int usable = MathMin(rates_total,historyDepth);

   bool is_series = true;
   if(rates_total > 1 && time[0] < time[rates_total-1])
      is_series = false;
   BuildChronologicalSequence(close, rates_total, usable, is_series);

   CSSA::SSAClearData(gSSAModel);
   CSSA::SSAAddSequence(gSSAModel,gSequence,usable);

   CSSA::SSAAnalyzeSequence(gSSAModel,gSequence,usable,gTrend,gNoise);

   if(prev_calculated==0)
     {
      for(int i=0;i<rates_total;i++)
        {
         gTrendBuffer[i]    = EMPTY_VALUE;
         gResidualBuffer[i] = EMPTY_VALUE;
         gZeroPhaseBuffer[i] = EMPTY_VALUE;
        }
      s_last_time0 = time[0];
     }

   if(s_last_time0 != 0 && time[0] != s_last_time0)
     {
      if(rates_total > 1)
        {
         gTrendBuffer[1] = gTrendBuffer[0];
         gResidualBuffer[1] = gResidualBuffer[0];
         gZeroPhaseBuffer[1] = gZeroPhaseBuffer[0];
        }
      s_last_time0 = time[0];
     }

   if(usable > 0)
     {
      gTrendBuffer[0] = gTrend[usable-1];
      gResidualBuffer[0] = InpShowResidual ? (close[0] - gTrend[usable-1]) : EMPTY_VALUE;
      gZeroPhaseBuffer[0] = EMPTY_VALUE;
     }

   DebugTimes(is_series, time, rates_total, is_series ? close[0] : close[rates_total - 1]);

   return(rates_total);
  }

//+------------------------------------------------------------------+
