//+------------------------------------------------------------------+
//| ShowSeriesLag.mq5                                                |
//| Overlay: show lag (bars) between price and indicator buffer      |
//+------------------------------------------------------------------+
#property script_show_inputs

#include "SeriesLag.mqh"

input string         IndicatorName   = "Sandbox\\Kalman3DRTS\\Kalman3DRTSZeroPhase_v3.1";
input ENUM_TIMEFRAMES IndicatorTF    = PERIOD_CURRENT;
input int            IndicatorBuffer = 0;
input int            LookbackBars    = 200;
input int            MaxLagBars      = 20;
input int            UpdateMs        = 1000;
input int            LabelX          = 10;
input int            LabelY          = 10;
input color          LabelColor      = clrDeepSkyBlue;

int gHandle = INVALID_HANDLE;
bool gRunning = true;

void OnStart()
{
   gHandle = iCustom(_Symbol, IndicatorTF, IndicatorName);
   if(gHandle == INVALID_HANDLE)
   {
      Print("ShowSeriesLag: iCustom handle failed.");
      return;
   }

   double ind[], price[];
   ArraySetAsSeries(ind, true);
   ArraySetAsSeries(price, true);

   while(gRunning && !IsStopped())
   {
      int want = MathMax(LookbackBars, MaxLagBars + 5);
      int got1 = CopyBuffer(gHandle, IndicatorBuffer, 0, want, ind);
      int got2 = CopyClose(_Symbol, _Period, 0, want, price);

      if(got1 > 10 && got2 > 10)
      {
         int len = MathMin(got1, got2);
         double corr = 0.0;
         int lag = EstimateLagBars(ind, price, MaxLagBars, MathMin(len, LookbackBars), corr);
         string txt = StringFormat("Lag: %d bars | corr=%.3f", lag, corr);
         DrawLagLabel("SERIES_LAG_LABEL", txt, LabelX, LabelY, LabelColor);
      }

      Sleep(UpdateMs);
   }

   if(gHandle != INVALID_HANDLE)
      IndicatorRelease(gHandle);
}
