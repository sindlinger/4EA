//+------------------------------------------------------------------+
//| IND_StdDev_FastSlow_Diff.mq5                                     |
//| StdDev(fast) - StdDev(slow) do Close (ou preço escolhido)        |
//+------------------------------------------------------------------+
#property strict
#property indicator_separate_window
#property indicator_buffers 1
#property indicator_plots   1
#property indicator_type1   DRAW_LINE
#property indicator_color1  clrDeepSkyBlue
#property indicator_label1  "StdDevFastSlowDiff"

input int  FastPeriod = 10;
input int  SlowPeriod = 50;
input ENUM_APPLIED_PRICE Price = PRICE_CLOSE;

double gOut[];
int hFast = INVALID_HANDLE;
int hSlow = INVALID_HANDLE;

int OnInit()
{
 //  if(FastPeriod < 2) FastPeriod = 2;
  // if(SlowPeriod < 2) SlowPeriod = 2;

   hFast = iStdDev(_Symbol, _Period, FastPeriod, 0, MODE_SMA, Price);
   hSlow = iStdDev(_Symbol, _Period, SlowPeriod, 0, MODE_SMA, Price);
   if(hFast == INVALID_HANDLE || hSlow == INVALID_HANDLE)
   {
      Print("Erro: nao conseguiu criar iStdDev.");
      return INIT_FAILED;
   }

   SetIndexBuffer(0, gOut, INDICATOR_DATA);
   ArraySetAsSeries(gOut, true);

   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   if(hFast != INVALID_HANDLE) IndicatorRelease(hFast);
   if(hSlow != INVALID_HANDLE) IndicatorRelease(hSlow);
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
   if(rates_total <= MathMax(FastPeriod, SlowPeriod))
      return 0;

   static double fast[];
   static double slow[];
   ArraySetAsSeries(fast, true);
   ArraySetAsSeries(slow, true);

   int need = rates_total;
   if(CopyBuffer(hFast, 0, 0, need, fast) <= 0) return prev_calculated;
   if(CopyBuffer(hSlow, 0, 0, need, slow) <= 0) return prev_calculated;

   for(int i=0; i<need; i++)
   {
      double f = fast[i];
      double s = slow[i];
      if(!MathIsValidNumber(f) || !MathIsValidNumber(s))
         gOut[i] = EMPTY_VALUE;
      else
         gOut[i] = f - s;
   }

   return rates_total;
}

