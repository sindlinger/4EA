#property indicator_separate_window
#property indicator_buffers 2
#property indicator_plots   2

#property indicator_label1  "SSA Green"
#property indicator_type1   DRAW_LINE
#property indicator_color1  clrLime
#property indicator_style1  STYLE_SOLID
#property indicator_width1  2

#property indicator_label2  "SSA Red"
#property indicator_type2   DRAW_LINE
#property indicator_color2  clrRed
#property indicator_style2  STYLE_SOLID
#property indicator_width2  2

input bool   InpUseSymbolPrefix = true;
input string InpGvGreenName = ""; // vazio = auto
input string InpGvRedName   = ""; // vazio = auto

// buffers
double gGreen[];
double gRed[];

string BuildGvName(const string base)
  {
   if(!InpUseSymbolPrefix)
      return(base);
   return(base + "_" + Symbol() + "_" + IntegerToString(Period()));
  }

int OnInit()
  {
   SetIndexBuffer(0, gGreen, INDICATOR_DATA);
   SetIndexBuffer(1, gRed, INDICATOR_DATA);
   ArraySetAsSeries(gGreen, true);
   ArraySetAsSeries(gRed, true);

   IndicatorSetInteger(INDICATOR_DIGITS, _Digits);
   IndicatorSetString(INDICATOR_SHORTNAME, "SSA Draw Stub");
   return(INIT_SUCCEEDED);
  }

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

   if(prev_calculated == 0)
     {
      for(int i=0;i<rates_total;i++)
        {
         gGreen[i] = EMPTY_VALUE;
         gRed[i] = EMPTY_VALUE;
        }
     }

   static datetime s_last_time0 = 0;
   if(s_last_time0 != 0 && time[0] != s_last_time0)
     {
      for(int i=rates_total-1; i>=1; --i)
        {
         gGreen[i] = gGreen[i-1];
         gRed[i] = gRed[i-1];
        }
     }
   s_last_time0 = time[0];

   string gvGreen = (InpGvGreenName == "" ? BuildGvName("SSA_GREEN") : InpGvGreenName);
   string gvRed   = (InpGvRedName == "" ? BuildGvName("SSA_RED") : InpGvRedName);

   if(GlobalVariableCheck(gvGreen))
      gGreen[0] = GlobalVariableGet(gvGreen);
   if(GlobalVariableCheck(gvRed))
      gRed[0] = GlobalVariableGet(gvRed);

   return(rates_total);
  }
