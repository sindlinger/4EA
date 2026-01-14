#property indicator_separate_window
#property indicator_buffers 2
#property indicator_plots   2

#property indicator_label1  "SSA Trend"
#property indicator_type1   DRAW_LINE
#property indicator_color1  clrLime
#property indicator_style1  STYLE_SOLID
#property indicator_width1  2

#property indicator_label2  "SSA Residual"
#property indicator_type2   DRAW_NONE
#property indicator_color2  clrDarkOrange
#property indicator_style2  STYLE_DOT
#property indicator_width2  1

#include <Math\Alglib\alglib.mqh>

input int  InpSSAWindow      = 64;   // Largura da janela SSA (>= 2)
input int  InpSSATopK        = 8;    // Componentes principais (>= 1)
input bool InpUseRealtimeAlg = false;// Usar algoritmo incremental (Top-K realtime)
input int  InpHistoryDepth   = 1024; // Máximo de barras consideradas
input int  InpRepaintBars    = 0;    // Repaint somente ate a barra (0 = so bar0)
input bool InpUseForecastRepaint = true; // Usa SSA forecast para simular futuro no repaint
input int  InpZeroPhaseHalfWindow = 0;   // Metade da janela (0 = auto = InpSSAWindow/2)

//--- buffers do indicador
double gTrendBuffer[];
double gResidualBuffer[];

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

   ArraySetAsSeries(gTrendBuffer,true);
   ArraySetAsSeries(gResidualBuffer,true);

   PlotIndexSetInteger(0,PLOT_DRAW_BEGIN,MathMax(InpSSAWindow-1,0));
   PlotIndexSetInteger(1,PLOT_DRAW_BEGIN,MathMax(InpSSAWindow-1,0));

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
   gForecast.Resize(0);
   gCenteredSequence.Resize(0);
   gCenteredTrend.Resize(0);
   gCenteredNoise.Resize(0);
   gTmpTrend.Resize(0);
   gTmpNoise.Resize(0);

   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
//| Limpeza                                                           |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   // Nada especial a fazer; objetos são destruídos automaticamente
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

//+------------------------------------------------------------------+
//| Sincroniza parâmetros do modelo SSA                              |
//+------------------------------------------------------------------+
void SyncModelParameters()
  {
   const int windowWidth = MathMax(InpSSAWindow,2);
   const int topK        = MathMin(MathMax(InpSSATopK,1),windowWidth);

   CSSA::SSASetWindow(gSSAModel,windowWidth);

   if(InpUseRealtimeAlg)
      CSSA::SSASetAlgoTopKRealtime(gSSAModel,topK);
   else
      CSSA::SSASetAlgoTopKDirect(gSSAModel,topK);

   PlotIndexSetInteger(0,PLOT_DRAW_BEGIN,windowWidth-1);
   PlotIndexSetInteger(1,PLOT_DRAW_BEGIN,windowWidth-1);
  }

int ResolveHalfWindow(const int windowWidth)
  {
   int half = InpZeroPhaseHalfWindow;
   if(half <= 0)
      half = windowWidth / 2;
   return(MathMax(1, half));
  }

bool BuildSSAForecast(const int usable,const int half)
  {
   if(half <= 0 || usable <= 0)
      return(false);

   const int windowWidth = MathMax(2, MathMin(InpSSAWindow, usable));
   const int topK = MathMin(MathMax(InpSSATopK,1), windowWidth);

   CSSA::SSASetWindow(gForecastModel, windowWidth);
   if(InpUseRealtimeAlg)
      CSSA::SSASetAlgoTopKRealtime(gForecastModel, topK);
   else
      CSSA::SSASetAlgoTopKDirect(gForecastModel, topK);

   CSSA::SSAClearData(gForecastModel);
   CSSA::SSAAddSequence(gForecastModel, gSequence, usable);

   // força cálculo da base para evitar forecast degenerado
   CSSA::SSAAnalyzeSequence(gForecastModel, gSequence, usable, gTmpTrend, gTmpNoise);
   CSSA::SSAForecastLast(gForecastModel, half, gForecast);
   return(gForecast.Size() >= half);
  }

bool BuildCenteredSequenceForC(const int c,const int half,const int usable)
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
         int fidx = idx - (usable - 1) - 1;
         if(fidx < 0 || fidx >= (int)gForecast.Size())
            return(false);
         gCenteredSequence.Set(j, gForecast[fidx]);
        }
     }
   return(true);
  }

bool ComputeZeroPhaseAtC(const int c,const int windowWidth,const int usable,double &trendOut)
  {
   int half = ResolveHalfWindow(windowWidth);
   if(usable < (half + 1) || half <= 0)
      return(false);

   if(!BuildSSAForecast(usable, half))
      return(false);

   int centerLen = 2 * half + 1;
   int centerWindow = MathMin(windowWidth, centerLen);

   if(!BuildCenteredSequenceForC(c, half, usable))
      return(false);

   int topK = MathMin(MathMax(InpSSATopK,1), centerWindow);
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
   return(true);
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
        }

      for(int bar=0; bar<usable; ++bar)
        {
         const double trendVal = gTrend[usable-1-bar];
         const double noiseVal = gNoise[usable-1-bar];

         gTrendBuffer[bar]    = trendVal;
         gResidualBuffer[bar] = noiseVal;
        }
     }
   else
     {
      int repaint = MathMax(0, InpRepaintBars);
      int max_bar = MathMin(usable-1, repaint);
      for(int bar=0; bar<=max_bar; ++bar)
        {
         const int c = usable - 1 - bar;
         double trendVal = 0.0;
         bool ok = false;
         if(InpUseForecastRepaint)
            ok = ComputeZeroPhaseAtC(c, windowWidth, usable, trendVal);
         if(!ok)
            trendVal = gTrend[c];

         gTrendBuffer[bar]    = trendVal;
         gResidualBuffer[bar] = gSequence[c] - trendVal;
        }
     }

   if(rates_total > 2)
     {
      string t0 = TimeToString(time[0], TIME_DATE|TIME_MINUTES);
      string t1 = TimeToString(time[1], TIME_DATE|TIME_MINUTES);
      string t2 = TimeToString(time[2], TIME_DATE|TIME_MINUTES);
      Comment(StringFormat("SSA debug | series=%s | t0=%s t1=%s t2=%s | repaint<=%d | forecast=%s",
                           is_series ? "true" : "false", t0, t1, t2, InpRepaintBars,
                           InpUseForecastRepaint ? "on" : "off"));
     }

   return(rates_total);
  }

//+------------------------------------------------------------------+
