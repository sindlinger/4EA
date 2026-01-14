#ifndef __SERIES_LAG_MQH__
#define __SERIES_LAG_MQH__

// Estimate lag (in bars) between two series using max correlation.
// Arrays must be Series (index 0 = most recent).
inline int EstimateLagBars(const double &a[], const double &b[], const int maxLag, const int len, double &out_corr)
{
   if(len <= maxLag + 2)
   {
      out_corr = 0.0;
      return 0;
   }

   double bestCorr = -1e10;
   int bestLag = 0;

   for(int lag = 0; lag <= maxLag; lag++)
   {
      double sumA = 0.0, sumB = 0.0, sumAA = 0.0, sumBB = 0.0, sumAB = 0.0;
      int n = 0;

      for(int i = 0; i < len; i++)
      {
         int ia = i + lag;
         int ib = i;
         if(ia >= len) break;

         double va = a[ia];
         double vb = b[ib];

         sumA += va; sumB += vb;
         sumAA += va * va; sumBB += vb * vb;
         sumAB += va * vb;
         n++;
      }

      if(n < 5) continue;
      double num = n * sumAB - sumA * sumB;
      double den = MathSqrt((n * sumAA - sumA * sumA) * (n * sumBB - sumB * sumB));
      if(den <= 1e-12) continue;
      double corr = num / den;

      if(corr > bestCorr)
      {
         bestCorr = corr;
         bestLag = lag;
      }
   }

   out_corr = bestCorr;
   return bestLag;
}

// Convenience overload when you don't need corr
inline int EstimateLagBars(const double &a[], const double &b[], const int maxLag, const int len)
{
   double corr = 0.0;
   return EstimateLagBars(a, b, maxLag, len, corr);
}

// Draw/update a label on chart with lag info
inline void DrawLagLabel(const string name, const string text, const int x, const int y, const color clr)
{
   if(ObjectFind(0, name) < 0)
   {
      ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);
      ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(0, name, OBJPROP_BACK, true);
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   }
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, 10);
   ObjectSetString(0, name, OBJPROP_FONT, "Arial");
   ObjectSetString(0, name, OBJPROP_TEXT, text);
}

#endif
