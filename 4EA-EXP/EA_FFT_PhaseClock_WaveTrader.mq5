//+------------------------------------------------------------------+
//| EA_FFT_PhaseClock_WaveTrader.mq5                                 |
//| Trades using FFT_PhaseClock wave direction (slope).               |
//| - Uses last CLOSED bar for signals (reduces repaint impact).      |
//| - Two-leg execution (or netting emulation) with partial exits.    |
//| - SL/TP, Break-even, Trailing stop.                               |
//+------------------------------------------------------------------+
#property strict
#property version   "1.00"

#include <Trade/Trade.mqh>

CTrade gTrade;

// ---------------- EA enums ----------------
enum SIGNAL_MODE
{
   SIG_TURN = 0,      // trade only when slope turns (down->up or up->down) on closed bars
   SIG_SLOPE,         // trade whenever slope is up/down on the last closed bar
   SIG_ZERO_CROSS     // trade on zero-cross (last closed bar)
};

enum LOT_MODE
{
   LOT_FIXED = 0,
   LOT_RISK_PERCENT
};

// ---------------- Inputs: indicator handle ----------------
input bool         UseChartIndicator   = true; // usa o indicador já anexado ao gráfico (mesmos inputs)
input string       InpIndicatorShortName = "FFT_PhaseClock_CLOSE_SINFLIP_LEAD_v1.5_ColorWave";
input string       InpIndicatorName    = "4EA-IND\\IND-FFT_PhaseClock_CLOSE_SINFLIP_LEAD_v1.5_ColorWave.ex5";

// ---------------- Inputs: lower timeframe confirmation ----------------
input bool            UseLowerTFConfirm = true;            // confirma entradas/saídas no TF inferior (barra fechada)
input ENUM_TIMEFRAMES SignalTimeframe   = PERIOD_M30;      // timeframe do gatilho (default M30)

// ---------------- Inputs: trading & risk ----------------
input SIGNAL_MODE  SignalMode          = SIG_TURN;
input bool         UseClosedBarSignals = true;   // true = use bar 1/2/3; false = bar 0/1/2 (more repaint-prone)
input double       MinSlopeAbs         = 0.0;    // ignore tiny slope turns (absolute delta in indicator units)

input bool         AllowBuy            = true;
input bool         AllowSell           = true;
input bool         CloseOnOpposite     = true;

input LOT_MODE     LotMode             = LOT_FIXED;
input double       FixedLots           = 0.10;
input double       RiskPercent         = 1.0;    // used only in LOT_RISK_PERCENT

input int          StopLossPoints      = 300;    // "stop" reference for R-multiples
input bool         UseBrokerTP         = true;   // place TP levels on server when possible
input int          SlippagePoints      = 20;
input int          MaxSpreadPoints     = 0;      // 0 = disabled

input int          MagicBase           = 12012026;

// ---------------- Inputs: multi-exit model ----------------
// Two legs:
// - Leg1: closes 100% at 1R (TP1_RR * stop distance)
// - Leg2: partial at TP2A and rest at TP2B (volume split sums to 100% of leg2)
input double       Leg1PercentOfTotal  = 50.0;   // percent of total lots for leg1
input double       Leg2PercentOfTotal  = 50.0;   // percent of total lots for leg2

input double       TP1_RR              = 1.0;    // 1:1 by default

input double       TP2A_StopPct        = 150.0;  // TP2A distance as % of stop (150 = 1.5R)
input double       TP2B_StopPct        = 300.0;  // TP2B distance as % of stop (300 = 3.0R)

input double       Leg2_CloseAtTP2A_Pct = 50.0;  // percent of leg2 volume to close at TP2A
input double       Leg2_CloseAtTP2B_Pct = 50.0;  // percent of leg2 volume to close at TP2B (usually remainder)

// ---------------- Inputs: break-even & trailing ----------------
input bool         EnableBreakEven     = true;
input double       BE_Trigger_R        = 1.0;    // move SL to BE after profit >= BE_Trigger_R * stop
input int          BE_OffsetPoints     = 0;      // BE+offset (buy) or BE-offset (sell)

input bool         EnableTrailing      = true;
input double       TrailStart_R        = 1.0;
input int          TrailDistancePoints = 200;
input int          TrailStepPoints     = 10;

// ---------------- Internals ----------------
int   gIndHandle = INVALID_HANDLE;
int   gConfirmHandle = INVALID_HANDLE;
datetime gLastBarTime = 0;
datetime gLastConfirmBarTime = 0;
bool  gOwnHandle = false;
bool  gOwnConfirmHandle = false;
ENUM_TIMEFRAMES gConfirmTF = PERIOD_CURRENT;

int MagicLeg1() { return MagicBase + 1; }
int MagicLeg2() { return MagicBase + 2; }
int MagicNet()  { return MagicBase + 10; }

bool IsHedgingAccount()
{
   long mode = AccountInfoInteger(ACCOUNT_MARGIN_MODE);
   return (mode == ACCOUNT_MARGIN_MODE_RETAIL_HEDGING);
}

int VolumeDigitsFromStep(double step)
{
   int d = 0;
   while(step < 1.0 && d < 8)
   {
      step *= 10.0;
      d++;
   }
   return d;
}

double NormalizeVolume(double vol)
{
   double vmin = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double vmax = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   if(step <= 0.0) step = vmin;

   vol = MathMax(vmin, MathMin(vmax, vol));
   vol = MathFloor(vol / step) * step;

   int d = VolumeDigitsFromStep(step);
   return NormalizeDouble(vol, d);
}

double ValuePerPointPerLot()
{
   double tick_value = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tick_size  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tick_size <= 0.0) return 0.0;
   return tick_value * (_Point / tick_size);
}

double ComputeTotalLotsByRisk(int stop_points)
{
   if(stop_points <= 0) return 0.0;

   double vpp = ValuePerPointPerLot();
   if(vpp <= 0.0) return 0.0;

   double risk_money = AccountInfoDouble(ACCOUNT_BALANCE) * (RiskPercent / 100.0);
   double risk_per_lot = vpp * stop_points;

   if(risk_per_lot <= 0.0) return 0.0;

   return NormalizeVolume(risk_money / risk_per_lot);
}

bool SpreadOk()
{
   if(MaxSpreadPoints <= 0) return true;
   int spread_points = (int)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   return (spread_points <= MaxSpreadPoints);
}

bool IsNewBar()
{
   datetime t0 = (datetime)iTime(_Symbol, _Period, 0);
   if(t0 == 0) return false;
   if(t0 != gLastBarTime)
   {
      gLastBarTime = t0;
      return true;
   }
   return false;
}

bool IsNewConfirmBar()
{
   if(!UseLowerTFConfirm)
      return IsNewBar();

   datetime t1 = (datetime)iTime(_Symbol, gConfirmTF, 1); // barra FECHADA do TF de confirmação
   if(t1 == 0) return false;
   if(t1 != gLastConfirmBarTime)
   {
      gLastConfirmBarTime = t1;
      return true;
   }
   return false;
}

int Sign(double x)
{
   if(x > 0.0) return 1;
   if(x < 0.0) return -1;
   return 0;
}

int FindChartIndicatorHandle(const string short_name)
{
   long chart_id = ChartID();
   int windows = (int)ChartGetInteger(chart_id, CHART_WINDOWS_TOTAL);
   if(windows <= 0) windows = 1;

   for(int w=0; w<windows; w++)
   {
      int icount = ChartIndicatorsTotal(chart_id, w);
      for(int i=0; i<icount; i++)
      {
         string name = ChartIndicatorName(chart_id, w, i);
         if(name == short_name || StringFind(name, short_name) == 0)
         {
            int h = ChartIndicatorGet(chart_id, w, name);
            if(h != INVALID_HANDLE)
               return h;
         }
      }
   }

   return INVALID_HANDLE;
}

bool GetWaveFromHandle(const int handle, double &v0, double &v1, double &v2, double &v3)
{
   if(handle == INVALID_HANDLE) return false;
   double buf[];
   ArrayResize(buf, 4);
   ArraySetAsSeries(buf, true);
   
   if(CopyBuffer(handle, 0, 0, 4, buf) != 4)
      return false;


   v0 = buf[0];
   v1 = buf[1];
   v2 = buf[2];
   v3 = buf[3];
   return true;
}

int ComputeSignal(const int handle, bool &is_buy, double &ref_stop_points, bool use_closed)
{
   // Returns: +1 buy, -1 sell, 0 none
   double v0, v1, v2, v3;
   if(!GetWaveFromHandle(handle, v0, v1, v2, v3))
      return 0;

   // choose bar shifts
   double a = use_closed ? v1 : v0;
   double b = use_closed ? v2 : v1;
   double c = use_closed ? v3 : v2;

   double slope_now  = a - b;
   double slope_prev = b - c;

   if(MathAbs(slope_now) < MinSlopeAbs) slope_now = 0.0;
   if(MathAbs(slope_prev) < MinSlopeAbs) slope_prev = 0.0;

   int sig = 0;

   if(SignalMode == SIG_TURN)
   {
      int d_now  = Sign(slope_now);
      int d_prev = Sign(slope_prev);

      if(d_now > 0 && d_prev <= 0) sig = +1;
      else if(d_now < 0 && d_prev >= 0) sig = -1;
   }
   else if(SignalMode == SIG_SLOPE)
   {
      int d_now = Sign(slope_now);
      if(d_now > 0) sig = +1;
      else if(d_now < 0) sig = -1;
   }
   else if(SignalMode == SIG_ZERO_CROSS)
   {
      // Cross zero between b and a
      if(b <= 0.0 && a > 0.0) sig = +1;
      else if(b >= 0.0 && a < 0.0) sig = -1;
   }

   if(sig == +1 && !AllowBuy) return 0;
   if(sig == -1 && !AllowSell) return 0;

   is_buy = (sig == +1);
   ref_stop_points = (double)StopLossPoints;
   return sig;
}

bool PositionExistsByTicket(ulong ticket)
{
   if(ticket == 0) return false;
   return PositionSelectByTicket(ticket);
}

ulong FindPositionTicketByMagic(const int magic)
{
   for(int i=PositionsTotal()-1; i>=0; --i)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;

      string sym = PositionGetString(POSITION_SYMBOL);
      if(sym != _Symbol) continue;

      int pmagic = (int)PositionGetInteger(POSITION_MAGIC);
      if(pmagic != magic) continue;

      return ticket;
   }
   return 0;
}

bool ClosePartialByTicket(ulong ticket, double volume)
{
   if(!PositionSelectByTicket(ticket)) return false;

   double vmin = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   volume = NormalizeVolume(volume);
   if(volume < vmin) return false;

   ENUM_POSITION_TYPE ptype = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
   ENUM_ORDER_TYPE   otype = (ptype == POSITION_TYPE_BUY ? ORDER_TYPE_SELL : ORDER_TYPE_BUY);

   MqlTradeRequest req;
   MqlTradeResult  res;
   ZeroMemory(req);
   ZeroMemory(res);

   req.action   = TRADE_ACTION_DEAL;
   req.position = ticket;
   req.symbol   = _Symbol;
   req.volume   = volume;
   req.type     = otype;
   req.deviation= SlippagePoints;
   req.magic    = (uint)MagicBase;

   req.price    = (otype == ORDER_TYPE_BUY ? SymbolInfoDouble(_Symbol, SYMBOL_ASK)
                                          : SymbolInfoDouble(_Symbol, SYMBOL_BID));

   bool ok = OrderSend(req, res);
   return ok && (res.retcode == TRADE_RETCODE_DONE || res.retcode == TRADE_RETCODE_DONE_PARTIAL);
}

bool ModifySLTPByTicket(ulong ticket, double sl, double tp)
{
   if(!PositionSelectByTicket(ticket)) return false;

   MqlTradeRequest req;
   MqlTradeResult  res;
   ZeroMemory(req);
   ZeroMemory(res);

   req.action   = TRADE_ACTION_SLTP;
   req.position = ticket;
   req.symbol   = _Symbol;
   req.sl       = sl;
   req.tp       = tp;
   req.magic    = (uint)MagicBase;

   bool ok = OrderSend(req, res);
   return ok && (res.retcode == TRADE_RETCODE_DONE);
}

void CloseAllOurPositions()
{
   for(int i=PositionsTotal()-1; i>=0; --i)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;

      string sym = PositionGetString(POSITION_SYMBOL);
      if(sym != _Symbol) continue;

      int pmagic = (int)PositionGetInteger(POSITION_MAGIC);
      if(pmagic != MagicLeg1() && pmagic != MagicLeg2() && pmagic != MagicNet())
         continue;

      // close full volume
      double vol = PositionGetDouble(POSITION_VOLUME);
      ClosePartialByTicket(ticket, vol);
   }
}

// ---------------- Trade plan (runtime) ----------------
struct TradePlan
{
   bool   active;
   bool   buy;
   double entry;
   double stop_points;
   double sl_price;

   double tp1;
   double tp2a;
   double tp2b;

   double lots_total;

   double lots_leg1;
   double lots_leg2;

   double lots_leg2_a;
   double lots_leg2_b;

   bool   leg1_done;
   bool   leg2a_done;

   ulong  ticket_leg1;
   ulong  ticket_leg2;
};

TradePlan gPlan;

void ResetPlan()
{
   ZeroMemory(gPlan);
   gPlan.active = false;
}

double PriceFromR(bool buy, double entry, double stop_points, double r_mult)
{
   double dist = stop_points * _Point * r_mult;
   return buy ? (entry + dist) : (entry - dist);
}

double PriceFromStopPct(bool buy, double entry, double stop_points, double pct)
{
   return PriceFromR(buy, entry, stop_points, pct / 100.0);
}

bool HasOurExposure()
{
   for(int i=PositionsTotal()-1; i>=0; --i)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;

      int pmagic = (int)PositionGetInteger(POSITION_MAGIC);
      if(pmagic == MagicLeg1() || pmagic == MagicLeg2() || pmagic == MagicNet())
         return true;
   }
   return false;
}

void SyncPlanTickets()
{
   if(!gPlan.active) return;

   if(IsHedgingAccount())
   {
      if(gPlan.ticket_leg1 == 0 || !PositionSelectByTicket(gPlan.ticket_leg1))
         gPlan.ticket_leg1 = FindPositionTicketByMagic(MagicLeg1());
      if(gPlan.ticket_leg2 == 0 || !PositionSelectByTicket(gPlan.ticket_leg2))
         gPlan.ticket_leg2 = FindPositionTicketByMagic(MagicLeg2());

      if(gPlan.ticket_leg1 == 0) gPlan.leg1_done = true;
      if(gPlan.ticket_leg2 == 0) gPlan.leg2a_done = true;
   }
   else
   {
      ulong t = FindPositionTicketByMagic(MagicNet());
      if(t == 0) ResetPlan();
   }
}

void ApplyBreakEvenAndTrailingToTicket(ulong ticket)
{
   if(!PositionSelectByTicket(ticket)) return;

   ENUM_POSITION_TYPE ptype = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
   bool buy = (ptype == POSITION_TYPE_BUY);

   double entry = PositionGetDouble(POSITION_PRICE_OPEN);
   double sl    = PositionGetDouble(POSITION_SL);
   double tp    = PositionGetDouble(POSITION_TP);

   double price = buy ? SymbolInfoDouble(_Symbol, SYMBOL_BID)
                      : SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   double profit_points = buy ? (price - entry) / _Point
                              : (entry - price) / _Point;

   // Break-even
   if(EnableBreakEven && gPlan.stop_points > 0.0)
   {
      double trigger = BE_Trigger_R * gPlan.stop_points;
      if(profit_points >= trigger)
      {
         int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
         double new_sl = buy ? (entry + BE_OffsetPoints * _Point)
                             : (entry - BE_OffsetPoints * _Point);
         new_sl = NormalizeDouble(new_sl, digits);

         bool improve = false;
         if(sl == 0.0) improve = true;
         else if(buy && new_sl > sl) improve = true;
         else if(!buy && new_sl < sl) improve = true;

         if(improve)
            ModifySLTPByTicket(ticket, new_sl, tp);
      }
   }

   // Trailing
   if(EnableTrailing && gPlan.stop_points > 0.0)
   {
      double start = TrailStart_R * gPlan.stop_points;
      if(profit_points >= start)
      {
         int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
         double desired = buy ? (SymbolInfoDouble(_Symbol, SYMBOL_BID) - TrailDistancePoints * _Point)
                              : (SymbolInfoDouble(_Symbol, SYMBOL_ASK) + TrailDistancePoints * _Point);
         desired = NormalizeDouble(desired, digits);

         bool improve = false;
         if(sl == 0.0) improve = true;
         else if(buy && desired > sl + TrailStepPoints * _Point) improve = true;
         else if(!buy && desired < sl - TrailStepPoints * _Point) improve = true;

         if(buy && desired >= SymbolInfoDouble(_Symbol, SYMBOL_BID)) improve = false;
         if(!buy && desired <= SymbolInfoDouble(_Symbol, SYMBOL_ASK)) improve = false;

         if(improve)
            ModifySLTPByTicket(ticket, desired, tp);
      }
   }
}

void ManageExitsAndStops()
{
   if(!gPlan.active)
      return;

   SyncPlanTickets();

   if(!HasOurExposure())
   {
      ResetPlan();
      return;
   }

   // Apply BE/Trailing
   if(IsHedgingAccount())
   {
      if(gPlan.ticket_leg1 != 0) ApplyBreakEvenAndTrailingToTicket(gPlan.ticket_leg1);
      if(gPlan.ticket_leg2 != 0) ApplyBreakEvenAndTrailingToTicket(gPlan.ticket_leg2);
   }
   else
   {
      ulong t = FindPositionTicketByMagic(MagicNet());
      if(t != 0) ApplyBreakEvenAndTrailingToTicket(t);
   }

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   // Exit logic
   if(IsHedgingAccount())
   {
      if(!UseBrokerTP && !gPlan.leg1_done && gPlan.ticket_leg1 != 0)
      {
         if((gPlan.buy && bid >= gPlan.tp1) || (!gPlan.buy && ask <= gPlan.tp1))
         {
            ClosePartialByTicket(gPlan.ticket_leg1, gPlan.lots_leg1);
            gPlan.leg1_done = true;
         }
      }

      if(!gPlan.leg2a_done && gPlan.ticket_leg2 != 0)
      {
         if((gPlan.buy && bid >= gPlan.tp2a) || (!gPlan.buy && ask <= gPlan.tp2a))
         {
            if(gPlan.lots_leg2_a > 0.0)
               ClosePartialByTicket(gPlan.ticket_leg2, gPlan.lots_leg2_a);
            gPlan.leg2a_done = true;
         }
      }

      if(!UseBrokerTP && gPlan.ticket_leg2 != 0)
      {
         if((gPlan.buy && bid >= gPlan.tp2b) || (!gPlan.buy && ask <= gPlan.tp2b))
         {
            if(PositionSelectByTicket(gPlan.ticket_leg2))
            {
               double v = PositionGetDouble(POSITION_VOLUME);
               ClosePartialByTicket(gPlan.ticket_leg2, v);
            }
         }
      }
   }
   else
   {
      ulong t = FindPositionTicketByMagic(MagicNet());
      if(t == 0) { ResetPlan(); return; }
      if(!PositionSelectByTicket(t)) { ResetPlan(); return; }

      double vpos = PositionGetDouble(POSITION_VOLUME);

      if(!gPlan.leg1_done)
      {
         if((gPlan.buy && bid >= gPlan.tp1) || (!gPlan.buy && ask <= gPlan.tp1))
         {
            double closev = MathMin(vpos, gPlan.lots_leg1);
            if(closev > 0.0) ClosePartialByTicket(t, closev);
            gPlan.leg1_done = true;
         }
      }

      if(!gPlan.leg2a_done)
      {
         if((gPlan.buy && bid >= gPlan.tp2a) || (!gPlan.buy && ask <= gPlan.tp2a))
         {
            if(PositionSelectByTicket(t))
            {
               vpos = PositionGetDouble(POSITION_VOLUME);
               double closev = MathMin(vpos, gPlan.lots_leg2_a);
               if(closev > 0.0) ClosePartialByTicket(t, closev);
            }
            gPlan.leg2a_done = true;
         }
      }

      if(!UseBrokerTP)
      {
         if((gPlan.buy && bid >= gPlan.tp2b) || (!gPlan.buy && ask <= gPlan.tp2b))
         {
            if(PositionSelectByTicket(t))
            {
               vpos = PositionGetDouble(POSITION_VOLUME);
               if(vpos > 0.0) ClosePartialByTicket(t, vpos);
            }
         }
      }
   }
}

bool OpenPlan(bool buy)
{
   if(StopLossPoints <= 0) { Print("StopLossPoints deve ser > 0."); return false; }
   if(!SpreadOk()) return false;

   double lots_total = (LotMode == LOT_FIXED) ? NormalizeVolume(FixedLots)
                                             : ComputeTotalLotsByRisk(StopLossPoints);

   if(lots_total <= 0.0)
   {
      Print("Lote total calculado inválido. Verifique parâmetros de risco/stop.");
      return false;
   }

   double lots_leg1 = NormalizeVolume(lots_total * (Leg1PercentOfTotal / 100.0));
   double lots_leg2 = NormalizeVolume(lots_total * (Leg2PercentOfTotal / 100.0));

   if(lots_leg1 + lots_leg2 <= 0.0) return false;

   double sum_exit = Leg2_CloseAtTP2A_Pct + Leg2_CloseAtTP2B_Pct;
   double a_pct = (sum_exit <= 0.0 ? 0.5 : (Leg2_CloseAtTP2A_Pct / sum_exit));

   double lots_leg2_a = NormalizeVolume(lots_leg2 * a_pct);
   double lots_leg2_b = NormalizeVolume(lots_leg2 - lots_leg2_a);

   double entry = buy ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

   double sl = buy ? (entry - StopLossPoints * _Point) : (entry + StopLossPoints * _Point);
   sl = NormalizeDouble(sl, digits);

   double tp1  = NormalizeDouble(PriceFromR(buy, entry, StopLossPoints, TP1_RR), digits);
   double tp2a = NormalizeDouble(PriceFromStopPct(buy, entry, StopLossPoints, TP2A_StopPct), digits);
   double tp2b = NormalizeDouble(PriceFromStopPct(buy, entry, StopLossPoints, TP2B_StopPct), digits);

   if(buy && tp2b <= tp2a) { double tmp=tp2a; tp2a=tp2b; tp2b=tmp; }
   if(!buy && tp2b >= tp2a) { double tmp=tp2a; tp2a=tp2b; tp2b=tmp; }

   ResetPlan();
   gPlan.active = true;
   gPlan.buy = buy;
   gPlan.entry = entry;
   gPlan.stop_points = (double)StopLossPoints;
   gPlan.sl_price = sl;
   gPlan.tp1 = tp1;
   gPlan.tp2a = tp2a;
   gPlan.tp2b = tp2b;

   gPlan.lots_total = lots_total;
   gPlan.lots_leg1 = lots_leg1;
   gPlan.lots_leg2 = lots_leg2;
   gPlan.lots_leg2_a = lots_leg2_a;
   gPlan.lots_leg2_b = lots_leg2_b;

   gPlan.leg1_done = false;
   gPlan.leg2a_done = false;

   gTrade.SetDeviationInPoints(SlippagePoints);

   if(IsHedgingAccount())
   {
      if(lots_leg1 > 0.0)
      {
         gTrade.SetExpertMagicNumber(MagicLeg1());
         bool ok1 = buy ? gTrade.Buy(lots_leg1, _Symbol, 0.0, sl, (UseBrokerTP ? tp1 : 0.0), "LEG1")
                        : gTrade.Sell(lots_leg1, _Symbol, 0.0, sl, (UseBrokerTP ? tp1 : 0.0), "LEG1");
         if(!ok1) Print("Falha ao abrir LEG1: ", gTrade.ResultRetcode(), " ", gTrade.ResultRetcodeDescription());
      }

      if(lots_leg2 > 0.0)
      {
         gTrade.SetExpertMagicNumber(MagicLeg2());
         bool ok2 = buy ? gTrade.Buy(lots_leg2, _Symbol, 0.0, sl, (UseBrokerTP ? tp2b : 0.0), "LEG2")
                        : gTrade.Sell(lots_leg2, _Symbol, 0.0, sl, (UseBrokerTP ? tp2b : 0.0), "LEG2");
         if(!ok2) Print("Falha ao abrir LEG2: ", gTrade.ResultRetcode(), " ", gTrade.ResultRetcodeDescription());
      }

      gPlan.ticket_leg1 = FindPositionTicketByMagic(MagicLeg1());
      gPlan.ticket_leg2 = FindPositionTicketByMagic(MagicLeg2());
   }
   else
   {
      gTrade.SetExpertMagicNumber(MagicNet());
      bool ok = buy ? gTrade.Buy(lots_total, _Symbol, 0.0, sl, (UseBrokerTP ? tp2b : 0.0), "NET")
                    : gTrade.Sell(lots_total, _Symbol, 0.0, sl, (UseBrokerTP ? tp2b : 0.0), "NET");
      if(!ok)
      {
         Print("Falha ao abrir posição NET: ", gTrade.ResultRetcode(), " ", gTrade.ResultRetcodeDescription());
         ResetPlan();
         return false;
      }
   }

   return true;
}

int OnInit()
{
   ResetPlan();

   gIndHandle = INVALID_HANDLE;
   gConfirmHandle = INVALID_HANDLE;
   gOwnHandle = false;
   gOwnConfirmHandle = false;

   gConfirmTF = UseLowerTFConfirm ? SignalTimeframe : _Period;
   if(gConfirmTF == PERIOD_CURRENT)
      gConfirmTF = _Period;

   if(UseChartIndicator)
      gIndHandle = FindChartIndicatorHandle(InpIndicatorShortName);

   if(gIndHandle == INVALID_HANDLE)
   {
      // Chama o indicador sem parâmetros para usar exatamente os defaults internos.
      gIndHandle = iCustom(_Symbol, _Period, InpIndicatorName);
      if(gIndHandle != INVALID_HANDLE)
         gOwnHandle = true;
   }

   if(gIndHandle == INVALID_HANDLE)
   {
      Print("Não foi possível criar handle do indicador. Nome: ", InpIndicatorName,
            " | ShortName: ", InpIndicatorShortName);
      return INIT_FAILED;
   }

   if(UseLowerTFConfirm)
   {
      if(gConfirmTF == _Period)
      {
         gConfirmHandle = gIndHandle;
      }
      else
      {
         gConfirmHandle = iCustom(_Symbol, gConfirmTF, InpIndicatorName);
         if(gConfirmHandle != INVALID_HANDLE)
            gOwnConfirmHandle = true;
      }

      if(gConfirmHandle == INVALID_HANDLE)
      {
         Print("Não foi possível criar handle de confirmação no TF: ", (int)gConfirmTF);
         return INIT_FAILED;
      }
   }

   gLastBarTime = (datetime)iTime(_Symbol, _Period, 0);
   gLastConfirmBarTime = (datetime)iTime(_Symbol, gConfirmTF, 1);
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   if(gOwnHandle && gIndHandle != INVALID_HANDLE)
      IndicatorRelease(gIndHandle);
   if(gOwnConfirmHandle && gConfirmHandle != INVALID_HANDLE)
      IndicatorRelease(gConfirmHandle);
}

void OnTick()
{
   ManageExitsAndStops();

   if(UseLowerTFConfirm)
   {
      if(!IsNewConfirmBar())
         return;
   }
   else if(UseClosedBarSignals)
   {
      if(!IsNewBar())
         return;
   }

   bool buy=false;
   double stop_pts=0.0;
   int sig = ComputeSignal(gIndHandle, buy, stop_pts, UseClosedBarSignals);
   if(sig == 0) return;

   if(UseLowerTFConfirm)
   {
      bool buy_c=false;
      double dummy=0.0;
      int sig_c = ComputeSignal(gConfirmHandle, buy_c, dummy, true); // confirmação sempre em barra fechada
      if(sig_c != sig)
         return;
   }

   if(HasOurExposure())
   {
      if(CloseOnOpposite)
      {
         bool current_buy = gPlan.active ? gPlan.buy : buy;
         if(gPlan.active && (buy != current_buy))
         {
            CloseAllOurPositions();
            ResetPlan();
            if(!HasOurExposure())
               OpenPlan(buy);
         }
      }
      return;
   }

   OpenPlan(buy);
}
