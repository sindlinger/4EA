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
#include "mql5_socket_client.mqh"

input int  InpSSAWindow      = 64;   // Largura da janela SSA (>= 2)
input int  InpSSATopK        = 8;    // Componentes principais (>= 1)
input bool InpUseRealtimeAlg = false;// Usar algoritmo incremental (Top-K realtime)
input int  InpHistoryDepth   = 1024; // Máximo de barras consideradas
input int  InpRepaintBars    = 0;    // Repaint somente ate a barra (0 = so bar0)
input bool InpUseForecastRepaint = true; // Usa SSA forecast para simular futuro no repaint
input int  InpZeroPhaseHalfWindow = 0;   // Metade da janela (0 = auto = InpSSAWindow/2)
input int  InpLinearLookback = 32;  // Lookback para forecast linear (>=2)

enum RepaintFutureMode
  {
   FUTURE_SSA_FORECAST = 0,
   FUTURE_MIRROR       = 1,
   FUTURE_LINEAR       = 2
  };
input RepaintFutureMode InpRepaintFutureMode = FUTURE_SSA_FORECAST; // Modo de futuro para repaint

//--- GPU (Python/CuPy) offload
input bool   InpUseGpu          = false;   // Usar SSA via GPU (socket TCP)
input string InpGpuHost         = "127.0.0.1";
input int    InpGpuPort         = 7789;
input uint   InpGpuTimeoutMs    = 500;
input bool   InpGpuEveryTick    = true;    // Recalcular GPU a cada tick (bar0)
input int    InpGpuMinBars      = 128;     // Min barras para GPU (evita chamadas curtas)
input bool   InpGpuLog          = true;    // Log de conexao/erros GPU
input int    InpGpuLogThrottleSec = 5;     // Intervalo minimo entre logs (s)

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

//--- GPU state
int    gGpuSock = INVALID_HANDLE;
double gGpuTrend[];
double gGpuCenteredSeries[];
double gGpuForecast[];
string gGpuLastError = "";
bool   gGpuLastOk = false;
datetime gGpuLastLogTime = 0;

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

   if(InpUseGpu)
      GpuEnsureSocket();

   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
//| Limpeza                                                           |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   // Nada especial a fazer; objetos são destruídos automaticamente
   if(gGpuSock != INVALID_HANDLE)
     {
      GpuSocketClose(gGpuSock);
      gGpuSock = INVALID_HANDLE;
     }
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

void GpuLog(const string msg, const bool force=false)
  {
   if(!InpGpuLog)
      return;
   datetime now = TimeCurrent();
   if(force || (now - gGpuLastLogTime) >= InpGpuLogThrottleSec)
     {
      Print(msg);
      gGpuLastLogTime = now;
     }
  }

void SetGpuError(const string msg)
  {
   if(msg == gGpuLastError)
      return;
   gGpuLastError = msg;
   gGpuLastOk = false;
   GpuLog("SSA GPU: " + msg, true);
  }

void SetGpuOk()
  {
   if(!gGpuLastOk)
      GpuLog("SSA GPU: connected", true);
   gGpuLastOk = true;
   gGpuLastError = "";
  }

bool JsonExtractArray(const string &json, const string &key, double &out[])
  {
   string pattern = "\"" + key + "\":[";
   int pos = StringFind(json, pattern);
   if(pos < 0)
      return(false);
   pos += StringLen(pattern);
   int end = StringFind(json, "]", pos);
   if(end < 0)
      return(false);
   string body = StringSubstr(json, pos, end - pos);
   if(StringLen(body) == 0)
     {
      ArrayResize(out, 0);
      return(true);
     }
   string parts[];
   int n = StringSplit(body, ',', parts);
   if(n <= 0)
     {
      ArrayResize(out, 0);
      return(true);
     }
   ArrayResize(out, n);
   for(int i=0; i<n; ++i)
     {
      string tmp = parts[i];
      StringTrimLeft(tmp);
      StringTrimRight(tmp);
      out[i] = StrToDouble(tmp);
     }
   return(true);
  }

bool JsonExtractString(const string &json, const string &key, string &out)
  {
   string pattern = "\"" + key + "\":\"";
   int pos = StringFind(json, pattern);
   if(pos < 0)
      return(false);
   pos += StringLen(pattern);
   int end = StringFind(json, "\"", pos);
   if(end < 0)
      return(false);
   out = StringSubstr(json, pos, end - pos);
   return(true);
  }

string BuildGpuRequest(const int usable,const int windowWidth,const int topK,const int half,const int repaint)
  {
   string json = "{";
   json += "\"version\":1,";
   json += "\"indicator\":\"IND-SSA_v1.0\",";
   json += "\"symbol\":\"" + Symbol() + "\",";
   json += "\"timeframe\":\"" + EnumToString((ENUM_TIMEFRAMES)Period()) + "\",";
   json += "\"window\":" + IntegerToString(windowWidth) + ",";
   json += "\"topk\":" + IntegerToString(topK) + ",";
   json += "\"half\":" + IntegerToString(half) + ",";
   json += "\"horizon\":" + IntegerToString(half) + ",";
   json += "\"repaint_bars\":" + IntegerToString(repaint) + ",";
   json += "\"linear_lookback\":" + IntegerToString(InpLinearLookback) + ",";
   json += "\"series_order\":\"chronological\",";
   json += "\"close\":[";
   for(int i=0; i<usable; ++i)
     {
      json += DoubleToString(gSequence[i], _Digits);
      if(i < usable - 1)
         json += ",";
     }
   json += "]}";
   return(json);
  }

bool GpuEnsureSocket()
  {
   if(!InpUseGpu)
      return(false);
   if(gGpuSock != INVALID_HANDLE)
      return(true);
   gGpuSock = GpuSocketConnect(InpGpuHost, (ushort)InpGpuPort, InpGpuTimeoutMs);
   if(gGpuSock == INVALID_HANDLE)
     {
      SetGpuError(StringFormat("connect failed (%s:%d) err=%d", InpGpuHost, InpGpuPort, GetLastError()));
      return(false);
     }
   SetGpuOk();
   return(true);
  }

bool GpuFetch(const int usable,const int windowWidth,const int topK,const int half,const int repaint)
  {
   if(!InpUseGpu || usable < InpGpuMinBars)
      return(false);
   if(!GpuEnsureSocket())
      return(false);

   string req = BuildGpuRequest(usable, windowWidth, topK, half, repaint);
   if(!GpuSocketSendJson(gGpuSock, req))
     {
      SetGpuError(StringFormat("send failed err=%d", GetLastError()));
      GpuSocketClose(gGpuSock);
      gGpuSock = INVALID_HANDLE;
      return(false);
     }

   string resp = "";
   if(!GpuSocketRecvJson(gGpuSock, resp, InpGpuTimeoutMs))
     {
      SetGpuError(StringFormat("recv failed err=%d", GetLastError()));
      GpuSocketClose(gGpuSock);
      gGpuSock = INVALID_HANDLE;
      return(false);
     }

   if(StringFind(resp, "\"ok\":true") < 0)
     {
      string err = "";
      if(JsonExtractString(resp, "err", err))
         SetGpuError("server err: " + err);
      else
         SetGpuError("server response not ok");
      return(false);
     }

   if(!JsonExtractArray(resp, "trend", gGpuTrend))
     {
      SetGpuError("invalid trend array");
      return(false);
     }
   if(!JsonExtractArray(resp, "trend_centered_series", gGpuCenteredSeries))
     {
      SetGpuError("invalid centered array");
      return(false);
     }
   JsonExtractArray(resp, "forecast", gGpuForecast);

   if(ArraySize(gGpuTrend) < usable)
     {
      SetGpuError("trend size < usable");
      return(false);
     }
   SetGpuOk();
   return(true);
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

bool BuildMirrorForecast(const int usable,const int half)
  {
   if(half <= 0 || usable <= 0)
      return(false);
   gForecast.Resize(half);
   for(int i=0;i<half;i++)
     {
      int src = usable - 2 - i;
      if(src < 0) src = 0;
      gForecast.Set(i, gSequence[src]);
     }
   return(true);
  }

bool BuildLinearForecast(const int usable,const int half)
  {
   if(half <= 0 || usable < 2)
      return(false);
   int lookback = MathMax(2, InpLinearLookback);
   if(lookback > usable)
      lookback = usable;

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

bool BuildFutureForecast(const int usable,const int half)
  {
   if(!InpUseForecastRepaint)
      return(false);
   if(InpRepaintFutureMode == FUTURE_MIRROR)
      return(BuildMirrorForecast(usable, half));
   if(InpRepaintFutureMode == FUTURE_LINEAR)
      return(BuildLinearForecast(usable, half));
   return(BuildSSAForecast(usable, half));
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

   if(!BuildFutureForecast(usable, half))
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

   const int topK = MathMin(MathMax(InpSSATopK,1), windowWidth);
   const int half = ResolveHalfWindow(windowWidth);
   const int repaint = MathMax(0, InpRepaintBars);

   static datetime s_last_time0 = 0;
   bool new_bar = (s_last_time0 != 0 && time[0] != s_last_time0);
   if(s_last_time0 == 0 || new_bar)
      s_last_time0 = time[0];

   bool gpu_ok = false;
   if(InpUseGpu && (prev_calculated == 0 || new_bar || InpGpuEveryTick))
      gpu_ok = GpuFetch(usable, windowWidth, topK, half, repaint);

   if(!gpu_ok)
     {
      CSSA::SSAClearData(gSSAModel);
      CSSA::SSAAddSequence(gSSAModel,gSequence,usable);
      CSSA::SSAAnalyzeSequence(gSSAModel,gSequence,usable,gTrend,gNoise);
     }

   if(prev_calculated==0)
     {
      for(int i=0;i<rates_total;i++)
        {
         gTrendBuffer[i]    = EMPTY_VALUE;
         gResidualBuffer[i] = EMPTY_VALUE;
        }

      for(int bar=0; bar<usable; ++bar)
        {
         const int c = usable - 1 - bar;
         double trendVal = gpu_ok ? gGpuTrend[c] : gTrend[c];
         double noiseVal = gSequence[c] - trendVal;

         gTrendBuffer[bar]    = trendVal;
         gResidualBuffer[bar] = noiseVal;
        }
     }

   // Sempre recalcular a faixa de repaint (inclui a barra 0)
   // usando janela centrada + forecast, garantindo qualidade da barra zero.
   int max_bar = MathMin(usable-1, repaint);
   for(int bar=0; bar<=max_bar; ++bar)
     {
      const int c = usable - 1 - bar;
      double trendVal = 0.0;
      bool ok = false;
      if(gpu_ok)
        {
         if(bar < ArraySize(gGpuCenteredSeries) && MathIsValidNumber(gGpuCenteredSeries[bar]))
            trendVal = gGpuCenteredSeries[bar];
         else
            trendVal = gGpuTrend[c];
        }
      else
        {
         if(InpUseForecastRepaint)
            ok = ComputeZeroPhaseAtC(c, windowWidth, usable, trendVal);
         if(!ok)
            trendVal = gTrend[c];
        }

      gTrendBuffer[bar]    = trendVal;
      gResidualBuffer[bar] = gSequence[c] - trendVal;
     }

   if(rates_total > 2)
     {
      string t0 = TimeToString(time[0], TIME_DATE|TIME_MINUTES);
      string t1 = TimeToString(time[1], TIME_DATE|TIME_MINUTES);
      string t2 = TimeToString(time[2], TIME_DATE|TIME_MINUTES);
      string mode = (InpRepaintFutureMode == FUTURE_MIRROR ? "mirror" :
                     (InpRepaintFutureMode == FUTURE_LINEAR ? "linear" : "ssa"));
      string gpu_state = (InpUseGpu ? (gGpuLastOk ? "ok" : "err") : "off");
      Comment(StringFormat("SSA debug | series=%s | t0=%s t1=%s t2=%s | repaint<=%d | forecast=%s | mode=%s | gpu=%s",
                           is_series ? "true" : "false", t0, t1, t2, InpRepaintBars,
                           InpUseForecastRepaint ? "on" : "off", mode,
                           gpu_state));
      }

   return(rates_total);
  }

//+------------------------------------------------------------------+
