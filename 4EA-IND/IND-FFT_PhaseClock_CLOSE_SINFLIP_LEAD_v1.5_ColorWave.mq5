//+------------------------------------------------------------------+
//| ATR_FFT_PhaseClock_OLA_Causal.mq5                                |
//| - Atualiza SOMENTE a barra 0 (última) a cada tick                |
//| - FFT causal (passado -> presente)                              |
//| - Bandpass + Analítico (Hilbert no espectro)                    |
//| - Relógio com ring + ponteiro "haste" (segmentos)               |
//+------------------------------------------------------------------+
#property strict
#property indicator_separate_window
#define INDICATOR_NAME "FFT_PhaseClock_CLOSE_SINFLIP_LEAD_v1.5_ColorWave"
#property indicator_buffers 4
#property indicator_plots   3
#property indicator_type1   DRAW_COLOR_LINE
#property indicator_color1  clrLimeGreen, clrRed
#property indicator_label1  INDICATOR_NAME
#property indicator_type2   DRAW_LINE
#property indicator_color2  clrDodgerBlue
#property indicator_label2  "Amplitude"
#property indicator_type3   DRAW_LINE
#property indicator_color3  clrGold
#property indicator_label3  "Qualidade"



#define CLOCK_MAX_DOTS  120
#define CLOCK_MAX_HAND  64



enum FEED_SOURCE
{
   FEED_ATR = 0,
   FEED_TR,
   FEED_CLOSE,
   FEED_HL2,
   FEED_HLC3,
   FEED_OHLC4,
   FEED_VOLUME,
   FEED_TICKVOLUME
};

enum WINDOW_TYPE
{
   WIN_HANN = 0,
   WIN_SINE,
   WIN_SQRT_HANN,
   WIN_KAISER
};

enum BAND_SHAPE
{
   BAND_RECT = 0,
   BAND_GAUSS
};

enum OUTPUT_MODE
{
   OUT_SIN = 0,
   OUT_COS,
   OUT_PHASE_RAD,
   OUT_PHASE_DEG
};

enum VIEW_MODE
{
   VIEW_WAVE = 0,
   VIEW_AMPLITUDE,
   VIEW_QUALITY
};

enum PAD_MODE
{
   PAD_ZERO = 0,
   PAD_MIRROR
};

// Forecast padding for realtime zero-phase (future bars)
enum FORECAST_MODE
{
   FC_MIRROR = 0,   // x[t+k] = x[t-k]
   FC_LINREG         // linear regression on recent bars
};

// ---------------- inputs ----------------
input FEED_SOURCE  FeedSource     = FEED_OHLC4;
input int          AtrPeriod      = 17;
input int          FFTSize        = 512;
input WINDOW_TYPE  WindowType     = WIN_SINE;
input double       KaiserBeta     = 4; // 8.6; DEFAULT

input bool         CausalWindow   = false; // janela com pico no presente (barra 0)

input bool         RemoveDC       = false;
input bool         ApplyBandpass  = true;
input int          CycleBars      = 17;
input double       BandwidthPct   = 200.0;
input BAND_SHAPE   BandShape      = BAND_RECT;

input OUTPUT_MODE  OutputMode     = OUT_SIN;
input bool         NormalizeAmp   = false;
input VIEW_MODE    StartView      = VIEW_WAVE;
input bool         QualityUsePhaseStability = true;
input double       QualityOmegaTolPct = 40.0; // tolerancia % para |dPhase|-omega
input double       PhaseOffsetDeg = 315;   // ajuste de fase aplicado na saída SIN/COS (graus)
input double       LeadBars         = 0;   // avanço de fase (em "barras") para reduzir atraso; 0 = original
input bool         LeadUseCycleOmega = true; // true: omega=2*pi/CycleBars (estável). false: omega por dPhase (experimental)
input double       LeadOmegaSmooth  = 0.6;  // suavização do omega quando LeadUseCycleOmega=false (0..1)
input int          LeadMinCycleBars = 9;     // clamp do período (modo experimental)
input int          LeadMaxCycleBars = 0;   // clamp do período (modo experimental)
input bool         InvertOutput   = true;  // inverte sinal da saída SIN/COS
input PAD_MODE     PadMode        = PAD_MIRROR;

// --- Realtime zero-phase (forward/backward) via forecast (lead bars) ---
// Quando true: usa janela simétrica centrada na barra 0 e preenche o futuro (meia-janela) com forecast.
// Resultado: barra 0 fica na posição correta (sem shift) e somente barra 0 + barras futuras repintam.
input bool         ZeroPhaseRT       = true;
input FORECAST_MODE ForecastMode     = FC_MIRROR;
input int          ForecastRegBars   = 32;   // usado apenas em FC_LINREG
input int          ForecastBars      = 0;    // 0 = automático (N/2 - 1)
input bool         ShowForecastLine  = false;
input int          ForecastDrawBars  = 0;   // 0 = desenhar todas as barras previstas
input color        ForecastLineColor = clrOrange;
input int          ForecastLineWidth = 1;

input bool         HoldPhaseOnLowAmp = true;
input double       LowAmpEps      = 1e-9;

// Clock visuals
input bool         ShowPhaseClock = false;
input int          ClockXOffset   = 110;     // dist da borda direita (px)
input int          ClockYOffset   = 55;      // dist do topo (px)
input int          ClockRadius    = 26;      // raio (px)

input bool         ClockShowRingDots = true;
input int          ClockRingDotsCount = 60;  // pontos no anel
input int          ClockRingDotSize   = 10;
input color        ClockRingColor     = clrSilver;

input bool         ClockShowNumbers   = true;
input int          ClockNumbersSize   = 10;
input color        ClockNumbersColor  = clrSilver;

input bool         ClockShowHand      = true;
input int          ClockHandSegments  = 9;   // quantos pontinhos formam a haste
input int          ClockHandDotSize   = 12;
input color        ClockHandColor     = clrRed;

input bool         ClockShowCenterDot = true;
input int          ClockCenterDotSize = 12;
input color        ClockCenterColor   = clrWhite;

input bool         ClockShowText      = true;

// ---------------- buffers ----------------
double gOut[];
double gColor[]; // 0=up (green), 1=down (red)
double gAmp[];
double gQuality[];

// ---------------- internals ----------------
int      gAtrHandle = INVALID_HANDLE;
int      gN = 0;
double   gWinCausal[];
double   gWinSym[];
double   gMask[];
double   gLastPhase = 0.0;
bool     gOmegaInit = false;
double   gLeadOmega = 0.0;
double   gPrevPhaseForOmega = 0.0;
bool     gMaskOk = true;
bool     gWarnedBand = false;
int      gViewMode = VIEW_WAVE;
bool     gQualityInit = false;
double   gPrevPhaseQuality = 0.0;

// object prefix for forecast/clock objects (must be declared before helpers)
string   gObjPrefix = INDICATOR_NAME + "_";
string   gPrevBtnName = INDICATOR_NAME + "_PREV";
string   gNextBtnName = INDICATOR_NAME + "_NEXT";

// forecast segments (objects)
int      gForecastSegs = 0;

// Subwindow onde o indicador está
int      gSubWin = -1;
// Detecta se os arrays de entrada chegam como series (0 = barra atual)
bool     gIsSeries = false;

// ---------------- UI helpers ----------------
void ApplyPlotView()
{
   PlotIndexSetInteger(0, PLOT_DRAW_TYPE, gViewMode == VIEW_WAVE ? DRAW_COLOR_LINE : DRAW_NONE);
   PlotIndexSetInteger(1, PLOT_DRAW_TYPE, gViewMode == VIEW_AMPLITUDE ? DRAW_LINE : DRAW_NONE);
   PlotIndexSetInteger(2, PLOT_DRAW_TYPE, gViewMode == VIEW_QUALITY ? DRAW_LINE : DRAW_NONE);
}

void EnsureViewButtons()
{
   EnsureSubWin();
   if(ObjectFind(0, gPrevBtnName) < 0)
   {
      ObjectCreate(0, gPrevBtnName, OBJ_BUTTON, gSubWin, 0, 0);
      ObjectSetInteger(0, gPrevBtnName, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(0, gPrevBtnName, OBJPROP_XDISTANCE, 8);
      ObjectSetInteger(0, gPrevBtnName, OBJPROP_YDISTANCE, 18);
      ObjectSetInteger(0, gPrevBtnName, OBJPROP_FONTSIZE, 8);
      ObjectSetInteger(0, gPrevBtnName, OBJPROP_COLOR, clrSilver);
      ObjectSetInteger(0, gPrevBtnName, OBJPROP_BORDER_COLOR, clrGray);
      ObjectSetInteger(0, gPrevBtnName, OBJPROP_BGCOLOR, clrBlack);
      ObjectSetInteger(0, gPrevBtnName, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, gPrevBtnName, OBJPROP_HIDDEN, true);
      ObjectSetString(0, gPrevBtnName, OBJPROP_TEXT, "Prev");
   }
   if(ObjectFind(0, gNextBtnName) < 0)
   {
      ObjectCreate(0, gNextBtnName, OBJ_BUTTON, gSubWin, 0, 0);
      ObjectSetInteger(0, gNextBtnName, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(0, gNextBtnName, OBJPROP_XDISTANCE, 52);
      ObjectSetInteger(0, gNextBtnName, OBJPROP_YDISTANCE, 18);
      ObjectSetInteger(0, gNextBtnName, OBJPROP_FONTSIZE, 8);
      ObjectSetInteger(0, gNextBtnName, OBJPROP_COLOR, clrSilver);
      ObjectSetInteger(0, gNextBtnName, OBJPROP_BORDER_COLOR, clrGray);
      ObjectSetInteger(0, gNextBtnName, OBJPROP_BGCOLOR, clrBlack);
      ObjectSetInteger(0, gNextBtnName, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, gNextBtnName, OBJPROP_HIDDEN, true);
      ObjectSetString(0, gNextBtnName, OBJPROP_TEXT, "Next");
   }
}

void DeleteViewButtons()
{
   ObjectDelete(0, gPrevBtnName);
   ObjectDelete(0, gNextBtnName);
}

// ---------------- FFT helpers ----------------
int NextPow2(int v){ int n=1; while(n < v) n <<= 1; return n; }



double WrapPi(const double a_in)
{
   double a = a_in;
   while(a >  M_PI) a -= 2.0*M_PI;
   while(a < -M_PI) a += 2.0*M_PI;
   return a;
}

void FFT(double &re[], double &im[], const bool inverse)
{
   int n = ArraySize(re);
   int j = 0;
   for(int i=1; i<n; i++)
   {
      int bit = n >> 1;
      while((j & bit) != 0){ j ^= bit; bit >>= 1; }
      j ^= bit;
      if(i < j)
      {
         double tr = re[i]; re[i] = re[j]; re[j] = tr;
         double ti = im[i]; im[i] = im[j]; im[j] = ti;
      }
   }
   for(int len=2; len<=n; len<<=1)
   {
      double ang = 2.0 * M_PI / len * (inverse ? -1.0 : 1.0);
      double wlen_re = MathCos(ang);
      double wlen_im = MathSin(ang);
      for(int i=0; i<n; i+=len)
      {
         double w_re = 1.0;
         double w_im = 0.0;
         for(int k=0; k<len/2; k++)
         {
            int u = i + k;
            int v = i + k + len/2;
            double vr = re[v]*w_re - im[v]*w_im;
            double vi = re[v]*w_im + im[v]*w_re;
            re[v] = re[u] - vr;
            im[v] = im[u] - vi;
            re[u] = re[u] + vr;
            im[u] = im[u] + vi;
            double next_re = w_re*wlen_re - w_im*wlen_im;
            double next_im = w_re*wlen_im + w_im*wlen_re;
            w_re = next_re;
            w_im = next_im;
         }
      }
   }
   if(inverse)
   {
      for(int i=0; i<n; i++){ re[i] /= n; im[i] /= n; }
   }
}

// Kaiser window
double I0(double x)
{
   double ax = MathAbs(x);
   double y;
   if(ax < 3.75)
   {
      y = x/3.75; y *= y;
      return 1.0 + y*(3.5156229 + y*(3.0899424 + y*(1.2067492 + y*(0.2659732 + y*(0.0360768 + y*0.0045813)))));
   }
   y = 3.75/ax;
   return (MathExp(ax)/MathSqrt(ax))*(0.39894228 + y*(0.01328592 + y*(0.00225319 + y*(-0.00157565 + y*(0.00916281 + y*(-0.02057706 + y*(0.02635537 + y*(-0.01647633 + y*0.00392377))))))));
}

int MirrorIndex(int idx, int len)
{
   if(len <= 1) return 0;
   if(idx < 0) idx = -idx;
   if(idx >= len) idx = 2*len - 2 - idx;
   if(idx < 0) idx = 0;
   if(idx >= len) idx = len - 1;
   return idx;
}

double GetSeriesSample(const double &src_series[], int sidx, int len)
{
   if(sidx >= 0 && sidx < len) return src_series[sidx];
   if(PadMode == PAD_ZERO) return 0.0;
   int m = MirrorIndex(sidx, len);
   return src_series[m];
}

bool ValidateBandBins(const int N)
{
   if(!ApplyBandpass || CycleBars <= 0) return true;
   double f0 = 1.0 / (double)CycleBars;
   double bw = BandwidthPct / 100.0;
   if(bw < 0.05) bw = 0.05;
   if(bw > 2.0)  bw = 2.0;
   double f1 = f0*(1.0 - 0.5*bw);
   double f2 = f0*(1.0 + 0.5*bw);
   if(f1 < 1e-6) f1 = 1e-6;
   if(f2 > 0.499999) f2 = 0.499999;
   if(f2 <= f1) f2 = f1 + 1e-6;
   int half = N/2;
   for(int k=0; k<=half; k++)
   {
      double f = (double)k/(double)N;
      if(f >= f1 && f <= f2) return true;
   }
   return false;
}

double BandWeight(const double f)
{
   if(!ApplyBandpass || CycleBars <= 0) return 1.0;

   double f0 = 1.0 / (double)CycleBars;
   double bw = BandwidthPct / 100.0;
   if(bw < 0.05) bw = 0.05;
   if(bw > 2.0)  bw = 2.0;

   double f1 = f0*(1.0 - 0.5*bw);
   double f2 = f0*(1.0 + 0.5*bw);

   if(f1 < 1e-6) f1 = 1e-6;
   if(f2 > 0.499999) f2 = 0.499999;
   if(f2 <= f1) f2 = f1 + 1e-6;

   if(f < f1 || f > f2) return 0.0;
   if(BandShape == BAND_RECT) return 1.0;

   double bw2 = (f2 - f1);
   double sigma = bw2 / 2.355;
   if(sigma <= 1e-12) return 1.0;
   double d = (f - f0)/sigma;
   return MathExp(-0.5*d*d);
}

void BuildWindowAndMask(const int N)
{
   gN = N;
   ArrayResize(gWinCausal, N);
   ArrayResize(gWinSym, N);
   ArrayResize(gMask, N);

   double denomI0 = I0(KaiserBeta);
   for(int n=0; n<N; n++)
   {
      // --- janela simétrica (pico no meio da janela) ---
      double ws = 1.0;
      if(WindowType == WIN_HANN)
         ws = 0.5 - 0.5*MathCos(2.0*M_PI*n/(N-1));
      else if(WindowType == WIN_SINE)
         ws = MathSin(M_PI*(n + 0.5)/N);
      else if(WindowType == WIN_SQRT_HANN)
      {
         double hann = 0.5 - 0.5*MathCos(2.0*M_PI*n/(N-1));
         ws = MathSqrt(hann);
      }
      else
      {
         double t = (2.0*n)/(double)(N-1) - 1.0;
         double val = KaiserBeta*MathSqrt(MathMax(0.0, 1.0 - t*t));
         ws = I0(val)/denomI0;
      }
      gWinSym[n] = ws;

      // --- janela causal (pico no presente / barra 0) ---
      // Observação: como o cálculo causal pega o sample no fim da janela (re[N-1]),
      // uma janela simétrica derruba a amplitude no "agora". Esta versão evita isso.
      double wc = 1.0;
      if(WindowType == WIN_HANN)
         wc = 0.5 - 0.5*MathCos(M_PI*n/(N-1));
      else if(WindowType == WIN_SINE)
         wc = MathSin(0.5*M_PI*(double)n/(double)(N-1));
      else if(WindowType == WIN_SQRT_HANN)
      {
         double hann = 0.5 - 0.5*MathCos(M_PI*n/(N-1));
         wc = MathSqrt(hann);
      }
      else
      {
         double u = (double)n/(double)(N-1);
         double tt = 1.0 - u;
         double val = KaiserBeta*MathSqrt(MathMax(0.0, 1.0 - tt*tt));
         wc = I0(val)/denomI0;
      }
      gWinCausal[n] = wc;
   }

   gMaskOk = ValidateBandBins(N);
   if(!gMaskOk && !gWarnedBand)
   {
      gWarnedBand = true;
      Print("?? Bandpass SEM bins p/ CycleBars=", CycleBars,
            " com FFTSize/N=", N,
            ". Ignorando bandpass (mantendo analítico) para não travar fase.");
   }

   int half = N/2;
   for(int k=0; k<N; k++)
   {
      double analytic = 0.0;
      if(k == 0) analytic = 1.0;
      else if((N % 2 == 0) && (k == half)) analytic = 1.0;
      else if(k > 0 && k < half) analytic = 2.0;
      else analytic = 0.0;

      double wband = 1.0;
      if(gMaskOk && ApplyBandpass && CycleBars > 0)
      {
         double f = (k <= half) ? (double)k/(double)N : (double)(N-k)/(double)N;
         wband = BandWeight(f);
      }

      gMask[k] = analytic * wband;
   }
}


int BarIndexFromShift(const int shift, const int total)
{
   // shift: 0 = barra atual, 1 = barra anterior, ...
   // Se os arrays vierem como series (0 = atual), usamos o shift direto.
   if(gIsSeries)
   {
      int idx = shift;
      if(idx < 0) idx = 0;
      if(idx >= total) idx = total - 1;
      return idx;
   }

   // Caso contrário, arrays em ordem cronológica (0 = mais antigo).
   int idx = total - 1 - shift;
   if(idx < 0) idx = 0;
   if(idx >= total) idx = total - 1;
   return idx;
}

// TR
double TrueRangeAtShift(const double &high[], const double &low[], const double &close[], int shift, int total)
{
   int idx = BarIndexFromShift(shift, total);
   int idx_prev = idx - 1;
   if(idx_prev < 0) idx_prev = 0;

   double h = high[idx];
   double l = low[idx];
   double pc = close[idx_prev];

   double tr1 = h - l;
   double tr2 = MathAbs(h - pc);
   double tr3 = MathAbs(l - pc);
   return MathMax(tr1, MathMax(tr2, tr3));
}

bool FetchSourceSeries(const int total, const double &open[], const double &high[], const double &low[], const double &close[],
                       const long &tick_volume[], const long &volume_arr[],
                       double &src_series[], const int needN)
{
   ArrayResize(src_series, needN);
   ArraySetAsSeries(src_series, true);

   if(FeedSource == FEED_ATR)
   {
      if(gAtrHandle == INVALID_HANDLE)
      {
         gAtrHandle = iATR(_Symbol, _Period, AtrPeriod);
         if(gAtrHandle == INVALID_HANDLE) return false;
      }
      int got = CopyBuffer(gAtrHandle, 0, 0, needN, src_series);
      return (got > 0);
   }

   for(int i=0; i<needN; i++)
   {
      int idx = BarIndexFromShift(i, total);

      double v = 0.0;
      switch(FeedSource)
      {
         case FEED_TR:       v = TrueRangeAtShift(high, low, close, i, total); break;
         case FEED_CLOSE:    v = close[idx]; break;
         case FEED_HL2:      v = (high[idx] + low[idx]) * 0.5; break;
         case FEED_HLC3:     v = (high[idx] + low[idx] + close[idx]) / 3.0; break;
         case FEED_OHLC4:    v = (open[idx] + high[idx] + low[idx] + close[idx]) / 4.0; break;
         case FEED_VOLUME:   v = (double)volume_arr[idx]; break;
         case FEED_TICKVOLUME: v = (double)tick_volume[idx]; break;
         default:            v = close[idx]; break;
      }
      src_series[i] = v;
   }
   return true;
}

bool ComputeBar0Phase_Causal(const int total,
                      const double &open[], const double &high[], const double &low[], const double &close[],
                      const long &tick_volume[], const long &volume_arr[],
                      double &out_value, double &out_phase, double &out_amp, double &out_quality)
{
   int N = gN;
   if(N <= 32) return false;

   double src_series[];
   if(!FetchSourceSeries(total, open, high, low, close, tick_volume, volume_arr, src_series, N))
      return false;

   double re[], im[];
   ArrayResize(re, N);
   ArrayResize(im, N);

   double mean = 0.0;
   // chrono: re[0]=mais antigo ... re[N-1]=mais recente (barra 0)
   for(int n=0; n<N; n++)
   {
      int sidx = (N-1 - n);
      double x = GetSeriesSample(src_series, sidx, N);
      re[n] = x; im[n] = 0.0;
      mean += x;
   }
   mean = (N>0 ? mean/(double)N : 0.0);

   for(int n=0; n<N; n++)
   {
      double x = re[n];
      if(RemoveDC) x -= mean;
      x *= (CausalWindow ? gWinCausal[n] : gWinSym[n]);
      re[n] = x;
      im[n] = 0.0;
   }

   FFT(re, im, false);
   double energy_total = 0.0;
   double energy_band = 0.0;
   for(int k=0; k<N; k++)
   {
      double r = re[k];
      double i = im[k];
      double e = r*r + i*i;
      energy_total += e;

      double m = gMask[k];
      double rm = r * m;
      double imv = i * m;
      energy_band += rm*rm + imv*imv;

      re[k] = rm;
      im[k] = imv;
   }
   FFT(re, im, true);

   double are = re[N-1];
   double aim = im[N-1];
   if(!MathIsValidNumber(are)) are = 0.0;
   if(!MathIsValidNumber(aim)) aim = 0.0;

   double phase = MathArctan2(aim, are);
   double amp   = MathSqrt(are*are + aim*aim);
   out_amp = amp;

   if(HoldPhaseOnLowAmp && amp < LowAmpEps)
      phase = gLastPhase;

   gLastPhase = phase;
   out_phase = phase;

   double q_energy = (energy_total > 0.0 ? (energy_band / energy_total) : 0.0);
   if(q_energy < 0.0) q_energy = 0.0;
   if(q_energy > 1.0) q_energy = 1.0;
   double q_stab = 1.0;
   if(QualityUsePhaseStability)
   {
      double cb = (CycleBars > 0 ? (double)CycleBars : 1.0);
      double omega = 2.0*M_PI / cb;
      if(!gQualityInit)
      {
         gQualityInit = true;
         gPrevPhaseQuality = phase;
         q_stab = 0.0;
      }
      else
      {
         double dph = WrapPi(phase - gPrevPhaseQuality);
         gPrevPhaseQuality = phase;
         double err = MathAbs(MathAbs(dph) - omega);
         double tol = omega * (QualityOmegaTolPct / 100.0);
         q_stab = (tol > 0.0 ? (1.0 - MathMin(1.0, err / tol)) : 0.0);
      }
   }
   if(q_stab < 0.0) q_stab = 0.0;
   if(q_stab > 1.0) q_stab = 1.0;
   out_quality = q_energy * q_stab;

      double omega_use = 0.0;
      // --- avanço de fase (reduz atraso sem usar futuro; pode antecipar demais se o ciclo mudar) ---
      if(LeadUseCycleOmega)
      {
         double cb = (CycleBars > 0 ? (double)CycleBars : 1.0);
         omega_use = 2.0*M_PI / cb;
      }
      else
      {
         // experimental: omega por derivada de fase (sensível a ticks; use com cuidado)
         if(!gOmegaInit)
         {
            gOmegaInit = true;
            gPrevPhaseForOmega = phase;
            gLeadOmega = (CycleBars > 0 ? (2.0*M_PI/(double)CycleBars) : 0.0);
         }
         else
         {
            double dph = WrapPi(phase - gPrevPhaseForOmega);
            gPrevPhaseForOmega = phase;

            if(!MathIsValidNumber(dph)) dph = 0.0;

            double a = LeadOmegaSmooth;
            if(a < 0.0) a = 0.0;
            if(a > 1.0) a = 1.0;
            gLeadOmega = (1.0-a)*gLeadOmega + a*dph;

            // clamp por período (modo experimental)
            int minCb = LeadMinCycleBars;
            int maxCb = LeadMaxCycleBars;
            if(minCb < 1) minCb = 1;
            if(maxCb < minCb) maxCb = minCb;

            double omega_min = 2.0*M_PI / (double)maxCb;
            double omega_max = 2.0*M_PI / (double)minCb;
            if(gLeadOmega < omega_min) gLeadOmega = omega_min;
            if(gLeadOmega > omega_max) gLeadOmega = omega_max;
         }
         omega_use = gLeadOmega;
      }

      // fase base (medida). Para OUT_PHASE_* devolvemos SEM lead.
      double phase_meas = phase;

      // fase usada para gerar SIN/COS (offset + lead)
      double phase_wave = phase + PhaseOffsetDeg * M_PI / 180.0 + LeadBars * omega_use;

      // mantém fase em um range razoável para evitar perda numérica
      if(phase_wave >  1000.0*M_PI || phase_wave < -1000.0*M_PI)
         phase_wave = MathMod(phase_wave, 2.0*M_PI);
      double s = MathSin(phase_wave);
      double c = MathCos(phase_wave);

      if(OutputMode == OUT_PHASE_RAD) out_value = phase_meas;
      else if(OutputMode == OUT_PHASE_DEG) out_value = phase_meas * 180.0 / M_PI;
      else if(OutputMode == OUT_COS) out_value = NormalizeAmp ? c : (c*amp);
      else out_value = NormalizeAmp ? s : (s*amp);

// opção de inversão (não afeta OUT_PHASE_*)
   if(InvertOutput && (OutputMode == OUT_SIN || OutputMode == OUT_COS))
      out_value = -out_value;

   if(!MathIsValidNumber(out_value)) out_value = 0.0;
   return true;
}

// ---------------- REALTIME ZERO-PHASE (forward/backward) ----------------

bool LinRegParams(const double &src_series[], const int len, int bars, double &out_b, double &out_m)
{
   if(bars < 2) bars = 2;
   if(bars > len) bars = len;
   if(bars < 2)
   {
      out_b = (len > 0 ? src_series[0] : 0.0);
      out_m = 0.0;
      return false;
   }

   double sum_i = 0.0, sum_i2 = 0.0, sum_y = 0.0, sum_iy = 0.0;
   for(int i=0; i<bars; i++)
   {
      double x = (double)i;
      double y = src_series[i];
      sum_i  += x;
      sum_i2 += x*x;
      sum_y  += y;
      sum_iy += x*y;
   }
   double n = (double)bars;
   double denom = n*sum_i2 - sum_i*sum_i;
   if(MathAbs(denom) < 1e-12)
   {
      out_b = sum_y / n;
      out_m = 0.0;
      return false;
   }
   out_m = (n*sum_iy - sum_i*sum_y) / denom;
   out_b = (sum_y - out_m*sum_i) / n;
   return true;
}

double ForecastSampleFuture(const double &src_series[], const int len, const int k,
                            const FORECAST_MODE mode, const double b, const double m)
{
   if(k <= 0) return src_series[0];
   if(mode == FC_MIRROR)
   {
      // mirror around bar 0: x[t+k] = x[t-k]
      int idx = k;
      if(idx < 0) idx = 0;
      if(idx >= len) idx = len - 1;
      return src_series[idx];
   }
   // linear regression on i=0..bars-1 (past). Future corresponds to i=-k.
   return b - m*(double)k;
}

bool ComputeBar0Phase_ZeroPhase(const int total,
                                const double &open[], const double &high[], const double &low[], const double &close[],
                                const long &tick_volume[], const long &volume_arr[],
                                double &out_value, double &out_phase, double &out_amp, double &out_quality,
                                double &out_future[], int &out_future_count)
{
   int N = gN;
   if(N <= 32) return false;
   int half = N/2;

   int fcount = ForecastBars;
   if(fcount <= 0) fcount = half - 1;
   if(fcount < 0) fcount = 0;
   if(fcount > half - 1) fcount = half - 1;
   out_future_count = fcount;
   ArrayResize(out_future, fcount);

   double src_series[];
   if(!FetchSourceSeries(total, open, high, low, close, tick_volume, volume_arr, src_series, N))
      return false;

   // precompute regression parameters if needed
   double b = 0.0, m = 0.0;
   if(ForecastMode == FC_LINREG)
      LinRegParams(src_series, N, ForecastRegBars, b, m);

   double re[], im[];
   ArrayResize(re, N);
   ArrayResize(im, N);

   // build centered series: indices n=0..N-1 correspond to t=-half..+half-1.
   double mean = 0.0;
   for(int n=0; n<N; n++)
   {
      int rel = n - half; // <=0 past, >0 future
      double x;
      if(rel <= 0)
      {
         int shift = -rel; // 0 = current, 1 = previous, ... half = N/2 bars back
         x = GetSeriesSample(src_series, shift, N);
      }
      else
      {
         x = ForecastSampleFuture(src_series, N, rel, ForecastMode, b, m);
      }
      re[n] = x;
      im[n] = 0.0;
      mean += x;
   }
   mean = (N > 0 ? mean/(double)N : 0.0);

   for(int n=0; n<N; n++)
   {
      double x = re[n];
      if(RemoveDC) x -= mean;
      x *= gWinSym[n];
      re[n] = x;
      im[n] = 0.0;
   }

   FFT(re, im, false);
   double energy_total = 0.0;
   double energy_band = 0.0;
   for(int k=0; k<N; k++)
   {
      double r = re[k];
      double i = im[k];
      double e = r*r + i*i;
      energy_total += e;

      double mm = gMask[k];
      double rm = r * mm;
      double imv = i * mm;
      energy_band += rm*rm + imv*imv;

      re[k] = rm;
      im[k] = imv;
   }
   FFT(re, im, true);

   int idx0 = half; // barra 0 alinhada ao centro (zero-phase)
   double are0 = re[idx0];
   double aim0 = im[idx0];
   if(!MathIsValidNumber(are0)) are0 = 0.0;
   if(!MathIsValidNumber(aim0)) aim0 = 0.0;

   double phase0 = MathArctan2(aim0, are0);
   double amp0   = MathSqrt(are0*are0 + aim0*aim0);
   out_amp = amp0;
   if(HoldPhaseOnLowAmp && amp0 < LowAmpEps)
      phase0 = gLastPhase;

   gLastPhase = phase0;
   out_phase = phase0;

   double q_energy = (energy_total > 0.0 ? (energy_band / energy_total) : 0.0);
   if(q_energy < 0.0) q_energy = 0.0;
   if(q_energy > 1.0) q_energy = 1.0;
   double q_stab = 1.0;
   if(QualityUsePhaseStability)
   {
      double cb = (CycleBars > 0 ? (double)CycleBars : 1.0);
      double omega = 2.0*M_PI / cb;
      if(!gQualityInit)
      {
         gQualityInit = true;
         gPrevPhaseQuality = phase0;
         q_stab = 0.0;
      }
      else
      {
         double dph = WrapPi(phase0 - gPrevPhaseQuality);
         gPrevPhaseQuality = phase0;
         double err = MathAbs(MathAbs(dph) - omega);
         double tol = omega * (QualityOmegaTolPct / 100.0);
         q_stab = (tol > 0.0 ? (1.0 - MathMin(1.0, err / tol)) : 0.0);
      }
   }
   if(q_stab < 0.0) q_stab = 0.0;
   if(q_stab > 1.0) q_stab = 1.0;
   out_quality = q_energy * q_stab;

   // omega for LeadBars
   double omega_use = 0.0;
   if(LeadUseCycleOmega)
   {
      double cb = (CycleBars > 0 ? (double)CycleBars : 1.0);
      omega_use = 2.0*M_PI / cb;
   }
   else
   {
      if(!gOmegaInit)
      {
         gOmegaInit = true;
         gPrevPhaseForOmega = phase0;
         gLeadOmega = (CycleBars > 0 ? (2.0*M_PI/(double)CycleBars) : 0.0);
      }
      else
      {
         double dph = WrapPi(phase0 - gPrevPhaseForOmega);
         gPrevPhaseForOmega = phase0;
         if(!MathIsValidNumber(dph)) dph = 0.0;

         double a = LeadOmegaSmooth;
         if(a < 0.0) a = 0.0;
         if(a > 1.0) a = 1.0;
         gLeadOmega = (1.0-a)*gLeadOmega + a*dph;

         int minCb = LeadMinCycleBars;
         int maxCb = LeadMaxCycleBars;
         if(minCb < 1) minCb = 1;
         if(maxCb < minCb) maxCb = minCb;
         double omega_min = 2.0*M_PI / (double)maxCb;
         double omega_max = 2.0*M_PI / (double)minCb;
         if(gLeadOmega < omega_min) gLeadOmega = omega_min;
         if(gLeadOmega > omega_max) gLeadOmega = omega_max;
      }
      omega_use = gLeadOmega;
   }

   // output for bar 0
   double phase_meas = phase0;
   double phase_wave = phase0 + PhaseOffsetDeg * M_PI / 180.0 + LeadBars * omega_use;
   if(phase_wave >  1000.0*M_PI || phase_wave < -1000.0*M_PI)
      phase_wave = MathMod(phase_wave, 2.0*M_PI);
   double s0 = MathSin(phase_wave);
   double c0 = MathCos(phase_wave);
   if(OutputMode == OUT_PHASE_RAD) out_value = phase_meas;
   else if(OutputMode == OUT_PHASE_DEG) out_value = phase_meas * 180.0 / M_PI;
   else if(OutputMode == OUT_COS) out_value = NormalizeAmp ? c0 : (c0*amp0);
   else out_value = NormalizeAmp ? s0 : (s0*amp0);
   if(InvertOutput && (OutputMode == OUT_SIN || OutputMode == OUT_COS))
      out_value = -out_value;
   if(!MathIsValidNumber(out_value)) out_value = 0.0;

   // future outputs (k=1..fcount)
   for(int fk=1; fk<=fcount; fk++)
   {
      int idx = idx0 + fk;
      if(idx < 0) idx = 0;
      if(idx >= N) idx = N-1;

      double are = re[idx];
      double aim = im[idx];
      if(!MathIsValidNumber(are)) are = 0.0;
      if(!MathIsValidNumber(aim)) aim = 0.0;
      double phase = MathArctan2(aim, are);
      double amp   = MathSqrt(are*are + aim*aim);
      if(HoldPhaseOnLowAmp && amp < LowAmpEps) phase = phase0;

      double pw = phase + PhaseOffsetDeg * M_PI / 180.0 + LeadBars * omega_use;
      if(pw >  1000.0*M_PI || pw < -1000.0*M_PI)
         pw = MathMod(pw, 2.0*M_PI);
      double ss = MathSin(pw);
      double cc = MathCos(pw);

      double v;
      if(OutputMode == OUT_PHASE_RAD) v = phase;
      else if(OutputMode == OUT_PHASE_DEG) v = phase * 180.0 / M_PI;
      else if(OutputMode == OUT_COS) v = NormalizeAmp ? cc : (cc*amp);
      else v = NormalizeAmp ? ss : (ss*amp);
      if(InvertOutput && (OutputMode == OUT_SIN || OutputMode == OUT_COS))
         v = -v;
      if(!MathIsValidNumber(v)) v = 0.0;
      out_future[fk-1] = v;
   }

   return true;
}

// Wrapper: choose causal vs realtime zero-phase.
// Important: does NOT shift the series; bar 0 stays in its real position.
// Past bars are not recomputed (only bar 0 and forecast objects update each tick).
bool ComputeBar0Phase(const int total,
                      const datetime &time[],
                      const double &open[], const double &high[], const double &low[], const double &close[],
                      const long &tick_volume[], const long &volume_arr[],
                      double &out_value, double &out_phase, double &out_amp, double &out_quality)
{
   if(!ZeroPhaseRT)
   {
      DeleteForecastObjects();
      return ComputeBar0Phase_Causal(total, open, high, low, close, tick_volume, volume_arr, out_value, out_phase, out_amp, out_quality);
   }

   double future_vals[];
   int future_count = 0;
   bool ok = ComputeBar0Phase_ZeroPhase(total, open, high, low, close, tick_volume, volume_arr,
                                       out_value, out_phase, out_amp, out_quality, future_vals, future_count);
   if(!ok)
   {
      DeleteForecastObjects();
      return false;
   }

   // time[] comes in chronological order (0=oldest ... total-1=newest) in this indicator.
   datetime t0 = time[BarIndexFromShift(0, total)];
   UpdateForecastObjects(t0, out_value, future_vals, future_count);
   return true;
}

// Forecast draw: use OBJ_TREND segments (no series shifting)
string ForecastSegName(const int idx){ return gObjPrefix + StringFormat("FCAST_%d", idx); }

void DeleteForecastObjects()
{
   for(int i=0; i<gForecastSegs; i++)
      ObjectDelete(0, ForecastSegName(i));
   gForecastSegs = 0;
}

void UpdateForecastObjects(const datetime t0, const double v0, const double &future_vals[], const int future_count)
{
   if(!ShowForecastLine || future_count <= 0)
   {
      DeleteForecastObjects();
      return;
   }
   EnsureSubWin();

   int draw = ForecastDrawBars;
   if(draw <= 0) draw = future_count;
   if(draw > future_count) draw = future_count;
   int segs = draw;

   int psec = PeriodSeconds(_Period);
   if(psec <= 0) psec = 60;

   for(int i=0; i<segs; i++)
   {
      datetime t1 = t0 + (datetime)(i)*psec;
      double   p1 = (i==0 ? v0 : future_vals[i-1]);
      datetime t2 = t0 + (datetime)(i+1)*psec;
      double   p2 = future_vals[i];

      string name = ForecastSegName(i);
      if(ObjectFind(0, name) < 0)
      {
         ObjectCreate(0, name, OBJ_TREND, gSubWin, t1, p1, t2, p2);
      }
      else
      {
         ObjectMove(0, name, 0, t1, p1);
         ObjectMove(0, name, 1, t2, p2);
      }
      ObjectSetInteger(0, name, OBJPROP_COLOR, ForecastLineColor);
      ObjectSetInteger(0, name, OBJPROP_WIDTH, ForecastLineWidth);
      ObjectSetInteger(0, name, OBJPROP_STYLE, STYLE_SOLID);
      ObjectSetInteger(0, name, OBJPROP_RAY_RIGHT, false);
      ObjectSetInteger(0, name, OBJPROP_RAY_LEFT, false);
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
   }

   // delete extras
   for(int i=segs; i<gForecastSegs; i++)
      ObjectDelete(0, ForecastSegName(i));
   gForecastSegs = segs;
}

// ---------------- CLOCK (arrumado) ----------------

string ClockNumName(const int idx){ return gObjPrefix + StringFormat("NUM_%d", idx); }
string ClockDotName(const int idx){ return gObjPrefix + StringFormat("RING_%d", idx); }
string ClockHandSegName(const int idx){ return gObjPrefix + StringFormat("HAND_%d", idx); }
string ClockCenterName(){ return gObjPrefix + "CENTER"; }
string ClockTextName(){ return gObjPrefix + "TEXT"; }

void EnsureSubWin()
{
   if(gSubWin >= 0) return;
   gSubWin = ChartWindowFind(0, INDICATOR_NAME);
   if(gSubWin < 0) gSubWin = 1; // fallback: primeiro subwindow
}

void SetLabel(const string name, const int xdist, const int ydist, const color col, const int fsz, const string text)
{
   EnsureSubWin();
   if(ObjectFind(0, name) < 0)
      ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);

   ObjectSetInteger(0, name, OBJPROP_CHART_ID, gSubWin);
   ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_RIGHT_UPPER);
   ObjectSetInteger(0, name, OBJPROP_ANCHOR, ANCHOR_CENTER);
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, xdist);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, ydist);
   ObjectSetInteger(0, name, OBJPROP_COLOR, col);
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, fsz);
   ObjectSetString (0, name, OBJPROP_FONT, "Arial");
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
   ObjectSetString (0, name, OBJPROP_TEXT, text);
}

void DeleteClockObjects()
{
   for(int i=0;i<12;i++) ObjectDelete(0, ClockNumName(i));
   for(int i=0;i<CLOCK_MAX_DOTS;i++) ObjectDelete(0, ClockDotName(i));
   for(int i=0;i<CLOCK_MAX_HAND;i++) ObjectDelete(0, ClockHandSegName(i));
   ObjectDelete(0, ClockCenterName());
   ObjectDelete(0, ClockTextName());
}

void UpdatePhaseClock(const double phase)
{
   if(!ShowPhaseClock){ DeleteClockObjects(); return; }

   EnsureSubWin();

   double ang = phase;
   if(ang < 0.0) ang += 2.0*M_PI;

   const int baseX = ClockXOffset;
   const int baseY = ClockYOffset;

   // Ring dots (o "círculo" de verdade)
   if(ClockShowRingDots)
   {
      int dots = ClockRingDotsCount;
      if(dots < 12) dots = 12;
      if(dots > CLOCK_MAX_DOTS) dots = CLOCK_MAX_DOTS;

      for(int i=0; i<dots; i++)
      {
         double a = -M_PI/2.0 + (2.0*M_PI)*(double)i/(double)dots;
         int dx = (int)MathRound(ClockRadius*MathCos(a));
         int dy = (int)MathRound(ClockRadius*MathSin(a));
         SetLabel(ClockDotName(i), baseX - dx, baseY + dy, ClockRingColor, ClockRingDotSize, "•");
      }
      // apaga sobras se diminuiu dots
      for(int i=dots; i<CLOCK_MAX_DOTS; i++)
         ObjectDelete(0, ClockDotName(i));
   }
   else
   {
      for(int i=0;i<CLOCK_MAX_DOTS;i++) ObjectDelete(0, ClockDotName(i));
   }

   // Números
   if(ClockShowNumbers)
   {
      int rnum = ClockRadius + 14;
      for(int i=0; i<12; i++)
      {
         int num = (i==0 ? 12 : i);
         double a = -M_PI/2.0 + (2.0*M_PI)*(double)i/12.0;
         int dx = (int)MathRound(rnum*MathCos(a));
         int dy = (int)MathRound(rnum*MathSin(a));
         SetLabel(ClockNumName(i), baseX - dx, baseY + dy, ClockNumbersColor, ClockNumbersSize, IntegerToString(num));
      }
   }
   else
   {
      for(int i=0;i<12;i++) ObjectDelete(0, ClockNumName(i));
   }

   // Ponteiro como "haste" (segmentos de pontos)
   if(ClockShowHand)
   {
      int segs = ClockHandSegments;
      if(segs < 3) segs = 3;
      if(segs > CLOCK_MAX_HAND) segs = CLOCK_MAX_HAND;

      // direção: ponteiro aponta para ang, mas ring está com 12h em -pi/2.
      // Aqui ang já está nesse sistema (0..2pi a partir do atan2).
      // Vamos girar para "12h" ficar em cima.
      double a = ang; // já ok com o relógio que desenhamos

      // comprimento interno (não encostar na borda)
      double L = (double)(ClockRadius - 2);
      double ux = MathCos(a);
      double uy = -MathSin(a);

      for(int s=1; s<=segs; s++)
      {
         double t = (double)s/(double)segs;     // 0..1
         int dx = (int)MathRound(L*t*ux);
         int dy = (int)MathRound(L*t*uy);
         SetLabel(ClockHandSegName(s-1), baseX - dx, baseY + dy, ClockHandColor, ClockHandDotSize, "•");
      }
      for(int s=segs; s<CLOCK_MAX_HAND; s++)
         ObjectDelete(0, ClockHandSegName(s));
   }
   else
   {
      for(int s=0;s<CLOCK_MAX_HAND;s++) ObjectDelete(0, ClockHandSegName(s));
   }

   // Ponto central
   if(ClockShowCenterDot)
      SetLabel(ClockCenterName(), baseX, baseY, ClockCenterColor, ClockCenterDotSize, "•");
   else
      ObjectDelete(0, ClockCenterName());

   // Texto (quadrante + grau)
   if(ClockShowText)
   {
      int quad = 1;
      if(ang >= M_PI/2.0 && ang < M_PI) quad = 2;
      else if(ang >= M_PI && ang < 3.0*M_PI/2.0) quad = 3;
      else if(ang >= 3.0*M_PI/2.0) quad = 4;

      string txt = StringFormat("Q%d  %.0f°", quad, ang*180.0/M_PI);
      SetLabel(ClockTextName(), baseX + 55, baseY + (ClockRadius + 18), clrWhite, 10, txt);
   }
   else
   {
      ObjectDelete(0, ClockTextName());
   }
}

// ---------------- MT5 lifecycle ----------------
int OnInit()
{
   IndicatorSetString(INDICATOR_SHORTNAME, INDICATOR_NAME);
      SetIndexBuffer(0, gOut, INDICATOR_DATA);
   SetIndexBuffer(1, gColor, INDICATOR_COLOR_INDEX);
   SetIndexBuffer(2, gAmp, INDICATOR_DATA);
   SetIndexBuffer(3, gQuality, INDICATOR_DATA);
   ArraySetAsSeries(gOut, true);
   ArraySetAsSeries(gColor, true);
   ArraySetAsSeries(gAmp, true);
   ArraySetAsSeries(gQuality, true);
IndicatorSetInteger(INDICATOR_DIGITS, 8);

   int N = NextPow2(MathMax(32, FFTSize));
   BuildWindowAndMask(N);
   gViewMode = (int)StartView;
   ApplyPlotView();
   PlotIndexSetInteger(0, PLOT_SHOW_DATA, false);
   PlotIndexSetInteger(1, PLOT_SHOW_DATA, false);
   PlotIndexSetInteger(2, PLOT_SHOW_DATA, false);

   if(FeedSource == FEED_ATR)
   {
      gAtrHandle = iATR(_Symbol, _Period, AtrPeriod);
      if(gAtrHandle == INVALID_HANDLE)
      {
         Print("Erro: nao conseguiu criar iATR.");
         return INIT_FAILED;
      }
   }

   PlotIndexSetInteger(0, PLOT_DRAW_BEGIN, N);
   PlotIndexSetInteger(1, PLOT_DRAW_BEGIN, N);
   PlotIndexSetInteger(2, PLOT_DRAW_BEGIN, N);
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   if(gAtrHandle != INVALID_HANDLE)
      IndicatorRelease(gAtrHandle);
   DeleteForecastObjects();
   DeleteClockObjects();
   DeleteViewButtons();
}

void OnChartEvent(const int id, const long &lparam, const double &dparam, const string &sparam)
{
   if(id == CHARTEVENT_OBJECT_CLICK && (sparam == gPrevBtnName || sparam == gNextBtnName))
   {
      if(sparam == gNextBtnName)
         gViewMode = (gViewMode + 1) % 3;
      else
         gViewMode = (gViewMode + 2) % 3;
      ApplyPlotView();
      ChartRedraw(0);
   }
}

int OnCalculate(const int rates_total,
                const int prev_calculated,
                const datetime& time[],
                const double& open[],
                const double& high[],
                const double& low[],
                const double& close[],
                const long& tick_volume[],
                const long& volume[],
                const int& spread[])
{
   int N = gN;
   if(rates_total >= 2)
      gIsSeries = (time[0] > time[rates_total - 1]);

   EnsureViewButtons();

   if(rates_total < N || N <= 32)
   {
      DeleteForecastObjects();
      UpdatePhaseClock(gLastPhase);
      return rates_total;
   }

   // rebuild se parâmetros mudaram
   static int lastFFT = -1, lastCycle = -1;
   static WINDOW_TYPE lastWin = (WINDOW_TYPE)-1;
   static double lastBW = -1.0, lastBeta = -1.0;
   static BAND_SHAPE lastBandShape = (BAND_SHAPE)-1;
   static bool lastBand = false;

   if(lastFFT != FFTSize || lastCycle != CycleBars || lastWin != WindowType ||
      lastBW != BandwidthPct || lastBeta != KaiserBeta || lastBandShape != BandShape || lastBand != ApplyBandpass)
   {
      int NN = NextPow2(MathMax(32, FFTSize));
      BuildWindowAndMask(NN);

      lastFFT = FFTSize;
      lastCycle = CycleBars;
      lastWin = WindowType;
      lastBW = BandwidthPct;
      lastBeta = KaiserBeta;
      lastBandShape = BandShape;
      lastBand = ApplyBandpass;
      gQualityInit = false;

      PlotIndexSetInteger(0, PLOT_DRAW_BEGIN, gN);
      PlotIndexSetInteger(1, PLOT_DRAW_BEGIN, gN);
      PlotIndexSetInteger(2, PLOT_DRAW_BEGIN, gN);
   }

   double outv=0.0, ph=0.0, amp=0.0, qual=0.0;
   if(ComputeBar0Phase(rates_total, time, open, high, low, close, tick_volume, volume, outv, ph, amp, qual))
   {
      gOut[0] = outv;        // <-- somente barra 0
      gAmp[0] = amp;
      gQuality[0] = qual;
      // Cor pela inclinação (comparando com a barra anterior já 'fechada')
      if(rates_total >= 2)
         gColor[0] = (gOut[0] >= gOut[1] ? 0.0 : 1.0);
      else
         gColor[0] = 0.0;

      UpdatePhaseClock(ph);
   }
   else
   {
      UpdatePhaseClock(gLastPhase);
   }

   return rates_total;
}
