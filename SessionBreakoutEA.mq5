//+------------------------------------------------------------------+
//|                                          SessionBreakoutEA.mq5   |
//|              Session First-15-Min Candle Breakout Expert Advisor |
//|                                                                  |
//| Strategy:                                                        |
//|  1. At the start of each configured session, record the HIGH     |
//|     and LOW of the first N × 15-minute candles (breakout range)  |
//|  2. Place a BUY STOP above the range high and a SELL STOP below  |
//|     the range low                                                |
//|  3. When one side is triggered, cancel the other                 |
//|  4. Optional bias filter: only take buys when price is above     |
//|     the 200 EMA on a higher timeframe (and vice versa for sells) |
//|  5. Market sessions are drawn as coloured background bands       |
//|  6. Trailing stop, break-even, daily loss limit, spread filter,  |
//|     range-size filter, RSI confluence, max-trades guard          |
//|                                                                  |
//| Designed for XAU/USD (GOLD) but works on any symbol.            |
//+------------------------------------------------------------------+
#property copyright "Copyright 2024"
#property version   "2.00"
#property strict

#include <Trade\Trade.mqh>

//--- Session time inputs (all times are broker server time, HH:MM)
input group "Session Windows (Server Time HH:MM)"
input string LondonOpen     = "08:00";   // London open time
input string LondonClose    = "17:00";   // London close time
input string NewYorkOpen    = "13:00";   // New York open time
input string NewYorkClose   = "22:00";   // New York close time
input string TokyoOpen      = "00:00";   // Tokyo open time
input string TokyoClose     = "09:00";   // Tokyo close time
input string SydneyOpen     = "22:00";   // Sydney open time  (prev-day 22:00)
input string SydneyClose    = "07:00";   // Sydney close time

input group "Breakout Settings"
input int    BreakoutCandles       = 3;     // Number of M15 candles that form the breakout range
input int    PendingOrderExpiry    = 60;    // Pending order expiry (minutes, 0 = no expiry)
input bool   CancelOppositeOnFill  = true;  // Cancel opposite pending when one is triggered
input int    NewsBlackoutMinutes   = 30;    // Minutes before/after a big-news hour to skip trading

input group "Trade Settings"
input double LotSize               = 0.1;   // Fixed lot size
input int    StopLossPips          = 150;   // Stop loss in pips (for XAU/USD: 150 pips = $1.50 per 0.01 lot)
input int    TakeProfitPips        = 300;   // Take profit in pips
input int    MagicNumber           = 654321;
input string TradeComment          = "SessionBreakout";
input int    SlippagePoints        = 20;
input ENUM_ORDER_TYPE_FILLING FillType = ORDER_FILLING_RETURN;

input group "Risk Management"
input bool   UseMoneyManagement    = true;  // Enable % risk lot sizing
input double RiskPercent           = 1.0;   // Risk per trade (% of balance)
input int    MaxTrades             = 2;     // Max concurrent open positions (0 = unlimited)
input double MaxDailyLossPercent   = 3.0;  // Stop trading when daily loss exceeds this % (0 = off)
input int    MaxSpreadPoints       = 50;   // Skip trade if spread > this many points (0 = off)

input group "Range Size Filter"
input int    MinRangePips          = 50;   // Skip if breakout range is narrower than this (pips)
input int    MaxRangePips          = 500;  // Skip if breakout range is wider than this (spike guard)

input group "Trailing Stop"
input bool   UseTrailingStop       = true; // Enable trailing stop loss
input int    TrailingStartPips     = 100;  // Profit in pips before trailing activates
input int    TrailingDistPips      = 80;   // Keep SL this many pips behind current price
input int    TrailingStepPips      = 20;   // Minimum SL improvement per move (pips)

input group "Break-Even"
input bool   UseBreakEven          = true; // Move SL to break-even after sufficient profit
input int    BreakEvenAtPips       = 100;  // Profit in pips required to activate break-even
input int    BreakEvenExtraPips    = 2;    // Extra pips beyond entry for the break-even SL

input group "RSI Confluence Filter"
input bool            UseRSIFilter   = false;       // Require RSI alignment before entry
input ENUM_TIMEFRAMES RSITimeframe   = PERIOD_M5;   // Timeframe for RSI calculation
input int             RSIPeriod      = 14;          // RSI period

input group "Bias Filter (Higher Timeframe)"
input bool              UseBiasFilter  = true;       // Filter trades by HTF trend
input ENUM_TIMEFRAMES   BiasTF         = PERIOD_H1;  // Bias timeframe
input int               BiasEMAPeriod  = 200;        // EMA period for bias

input group "Session Highlight Colours"
input color LondonColor    = C'173,216,230'; // London highlight colour  (light blue)
input color NewYorkColor   = C'255,228,196'; // New York highlight colour (bisque)
input color TokyoColor     = C'221,255,221'; // Tokyo highlight colour   (light green)
input color SydneyColor    = C'255,240,245'; // Sydney highlight colour  (lavender blush)
input bool  DrawSessions   = true;           // Draw session bands on chart

//+------------------------------------------------------------------+
//| Internal structures                                              |
//+------------------------------------------------------------------+
struct SessionInfo
  {
   string   name;
   int      openHour, openMin;
   int      closeHour, closeMin;
   color    clr;
   bool     isActive;
   datetime lastSetupTime;   // time of last breakout setup
   double   rangeHigh;
   double   rangeLow;
   ulong    buyStopTicket;
   ulong    sellStopTicket;
  };

//+------------------------------------------------------------------+
//| Globals                                                          |
//+------------------------------------------------------------------+
CTrade     trade;
int        biasEMAHandle    = INVALID_HANDLE;
int        rsiHandle        = INVALID_HANDLE;
double     dailyStartBalance = 0;
datetime   lastDayChecked   = 0;

SessionInfo sessions[4]; // London, NewYork, Tokyo, Sydney

//+------------------------------------------------------------------+
//| Parse "HH:MM" string into hours and minutes                      |
//+------------------------------------------------------------------+
bool ParseTime(const string t, int &h, int &m)
  {
   string parts[];
   if(StringSplit(t, ':', parts) != 2)
      return false;
   h = (int)StringToInteger(parts[0]);
   m = (int)StringToInteger(parts[1]);
   return (h >= 0 && h <= 23 && m >= 0 && m <= 59);
  }

//+------------------------------------------------------------------+
//| Build the four session descriptors from inputs                   |
//+------------------------------------------------------------------+
void InitSessions()
  {
   int oh, om, ch, cm;

   // London
   sessions[0].name = "London";
   sessions[0].clr  = LondonColor;
   ParseTime(LondonOpen,  oh, om); sessions[0].openHour  = oh; sessions[0].openMin  = om;
   ParseTime(LondonClose, ch, cm); sessions[0].closeHour = ch; sessions[0].closeMin = cm;

   // New York
   sessions[1].name = "New York";
   sessions[1].clr  = NewYorkColor;
   ParseTime(NewYorkOpen,  oh, om); sessions[1].openHour  = oh; sessions[1].openMin  = om;
   ParseTime(NewYorkClose, ch, cm); sessions[1].closeHour = ch; sessions[1].closeMin = cm;

   // Tokyo
   sessions[2].name = "Tokyo";
   sessions[2].clr  = TokyoColor;
   ParseTime(TokyoOpen,  oh, om); sessions[2].openHour  = oh; sessions[2].openMin  = om;
   ParseTime(TokyoClose, ch, cm); sessions[2].closeHour = ch; sessions[2].closeMin = cm;

   // Sydney
   sessions[3].name = "Sydney";
   sessions[3].clr  = SydneyColor;
   ParseTime(SydneyOpen,  oh, om); sessions[3].openHour  = oh; sessions[3].openMin  = om;
   ParseTime(SydneyClose, ch, cm); sessions[3].closeHour = ch; sessions[3].closeMin = cm;

   for(int i = 0; i < 4; i++)
     {
      sessions[i].isActive       = false;
      sessions[i].lastSetupTime  = 0;
      sessions[i].rangeHigh      = 0;
      sessions[i].rangeLow       = 0;
      sessions[i].buyStopTicket  = 0;
      sessions[i].sellStopTicket = 0;
     }
  }

//+------------------------------------------------------------------+
//| On restart: scan live pending orders and restore session tickets  |
//+------------------------------------------------------------------+
void RestoreSessionTickets()
  {
   int total = OrdersTotal();
   for(int i = 0; i < total; i++)
     {
      ulong ticket = OrderGetTicket(i);
      if(!OrderSelect(ticket))                          continue;
      if(OrderGetString(ORDER_SYMBOL) != _Symbol)       continue;
      if(OrderGetInteger(ORDER_MAGIC) != MagicNumber)   continue;

      ENUM_ORDER_TYPE otype = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);

      for(int s = 0; s < 4; s++)
        {
         if(otype == ORDER_TYPE_BUY_STOP && sessions[s].buyStopTicket == 0)
           {
            sessions[s].buyStopTicket = ticket;
            Print("Restored BUY STOP #", ticket, " for ", sessions[s].name);
           }
         else if(otype == ORDER_TYPE_SELL_STOP && sessions[s].sellStopTicket == 0)
           {
            sessions[s].sellStopTicket = ticket;
            Print("Restored SELL STOP #", ticket, " for ", sessions[s].name);
           }
        }
     }
  }

//+------------------------------------------------------------------+
//| Return true if a pending order was genuinely filled              |
//+------------------------------------------------------------------+
bool WasOrderFilled(ulong ticket)
  {
   if(ticket == 0)         return false;
   if(OrderSelect(ticket)) return false;  // still pending → not filled
   if(HistoryOrderSelect(ticket))
     {
      ENUM_ORDER_STATE state = (ENUM_ORDER_STATE)HistoryOrderGetInteger(ticket, ORDER_STATE);
      return (state == ORDER_STATE_FILLED);
     }
   return false;
  }

//+------------------------------------------------------------------+
//| Count open positions belonging to this EA on this symbol         |
//+------------------------------------------------------------------+
int CountOpenPositions()
  {
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket))                   continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)     continue;
      if(PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
      count++;
     }
   return count;
  }

//+------------------------------------------------------------------+
//| Reset daily start balance at the beginning of each new day       |
//+------------------------------------------------------------------+
void CheckResetDailyBalance()
  {
   if(MaxDailyLossPercent <= 0)
      return;
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   dt.hour = 0; dt.min = 0; dt.sec = 0;
   datetime today = StructToTime(dt);
   if(today != lastDayChecked)
     {
      dailyStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
      lastDayChecked    = today;
     }
  }

//+------------------------------------------------------------------+
//| Return true when today's drawdown has exceeded the daily limit   |
//+------------------------------------------------------------------+
bool IsDailyLossLimitReached()
  {
   if(MaxDailyLossPercent <= 0 || dailyStartBalance <= 0)
      return false;
   double equity    = AccountInfoDouble(ACCOUNT_EQUITY);
   double lossLimit = dailyStartBalance * MaxDailyLossPercent / 100.0;
   return (dailyStartBalance - equity >= lossLimit);
  }

//+------------------------------------------------------------------+
//| Return true if the current spread is within the allowed limit    |
//+------------------------------------------------------------------+
bool IsSpreadOK()
  {
   if(MaxSpreadPoints <= 0)
      return true;
   double spreadPoints = (SymbolInfoDouble(_Symbol, SYMBOL_ASK) - SymbolInfoDouble(_Symbol, SYMBOL_BID))
                         / SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   return (spreadPoints <= MaxSpreadPoints);
  }

//+------------------------------------------------------------------+
//| Check if a given server-time is within a session window          |
//| Handles overnight sessions (open > close, e.g. Sydney 22-07)    |
//+------------------------------------------------------------------+
bool IsInSession(const SessionInfo &s, int curHour, int curMin)
  {
   int cur   = curHour * 60 + curMin;
   int start = s.openHour  * 60 + s.openMin;
   int stop  = s.closeHour * 60 + s.closeMin;

   if(start < stop)
      return (cur >= start && cur < stop);
   else // overnight
      return (cur >= start || cur < stop);
  }

//+------------------------------------------------------------------+
//| Return true if current time is within NewsBlackoutMinutes of a  |
//| top-of-hour (crude news-window guard)                            |
//+------------------------------------------------------------------+
bool IsNewsWindow(datetime t)
  {
   if(NewsBlackoutMinutes <= 0)
      return false;
   MqlDateTime dt;
   TimeToStruct(t, dt);
   int minsPastHour = dt.min;
   int minsToHour   = 60 - minsPastHour;
   return (minsPastHour < NewsBlackoutMinutes || minsToHour <= NewsBlackoutMinutes);
  }

//+------------------------------------------------------------------+
//| Higher-timeframe bias: +1 = bullish, -1 = bearish, 0 = neutral  |
//+------------------------------------------------------------------+
int GetBias()
  {
   if(!UseBiasFilter || biasEMAHandle == INVALID_HANDLE)
      return 0; // disabled → no filter

   double ema[];
   ArraySetAsSeries(ema, true);
   if(CopyBuffer(biasEMAHandle, 0, 0, 1, ema) < 1)
      return 0;

   double price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(price > ema[0]) return  1;
   if(price < ema[0]) return -1;
   return 0;
  }

//+------------------------------------------------------------------+
//| RSI momentum bias: +1 = bullish (>50), -1 = bearish (<50)       |
//+------------------------------------------------------------------+
int GetRSIBias()
  {
   if(!UseRSIFilter || rsiHandle == INVALID_HANDLE)
      return 0; // disabled → no filter

   double rsiVal[];
   ArraySetAsSeries(rsiVal, true);
   if(CopyBuffer(rsiHandle, 0, 0, 1, rsiVal) < 1)
      return 0;

   if(rsiVal[0] > 50.0) return  1;
   if(rsiVal[0] < 50.0) return -1;
   return 0;
  }

//+------------------------------------------------------------------+
//| Draw a session highlight rectangle on the chart                  |
//+------------------------------------------------------------------+
void DrawSessionRect(const string name, datetime t1, datetime t2, color clr)
  {
   if(!DrawSessions)
      return;

   double hi = ChartGetDouble(0, CHART_PRICE_MAX);
   double lo = ChartGetDouble(0, CHART_PRICE_MIN);

   if(ObjectFind(0, name) < 0)
      ObjectCreate(0, name, OBJ_RECTANGLE, 0, t1, hi, t2, lo);
   else
     {
      ObjectSetInteger(0, name, OBJPROP_TIME,  0, t1);
      ObjectSetInteger(0, name, OBJPROP_TIME,  1, t2);
      ObjectSetDouble (0, name, OBJPROP_PRICE, 0, hi);
      ObjectSetDouble (0, name, OBJPROP_PRICE, 1, lo);
     }

   ObjectSetInteger(0, name, OBJPROP_COLOR,   clr);
   ObjectSetInteger(0, name, OBJPROP_FILL,    true);
   ObjectSetInteger(0, name, OBJPROP_BACK,    true);
   ObjectSetInteger(0, name, OBJPROP_WIDTH,   1);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
  }

//+------------------------------------------------------------------+
//| Draw a horizontal line (range high / low)                        |
//+------------------------------------------------------------------+
void DrawRangeLine(const string name, double price, color clr, ENUM_LINE_STYLE style)
  {
   if(ObjectFind(0, name) < 0)
      ObjectCreate(0, name, OBJ_HLINE, 0, 0, price);
   else
      ObjectSetDouble(0, name, OBJPROP_PRICE, price);
   ObjectSetInteger(0, name, OBJPROP_COLOR,     clr);
   ObjectSetInteger(0, name, OBJPROP_STYLE,     style);
   ObjectSetInteger(0, name, OBJPROP_WIDTH,     1);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
  }

//+------------------------------------------------------------------+
//| Return the point-to-pip multiplier                               |
//+------------------------------------------------------------------+
int PipMultiplier()
  {
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   return (digits == 3 || digits == 5) ? 10 : 1;
  }

//+------------------------------------------------------------------+
//| Normalize lot to broker constraints                              |
//+------------------------------------------------------------------+
double NormalizeLot(double lot)
  {
   double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   lot = MathFloor(lot / lotStep) * lotStep;
   lot = MathMax(minLot, MathMin(maxLot, lot));
   int decimals = MathMax(0, (int)MathRound(-MathLog10(lotStep)));
   return NormalizeDouble(lot, decimals);
  }

//+------------------------------------------------------------------+
//| Calculate lot size (fixed or risk-based)                         |
//+------------------------------------------------------------------+
double CalculateLotSize(double slDistance)
  {
   if(!UseMoneyManagement || slDistance <= 0)
      return NormalizeLot(LotSize);

   double balance    = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskAmt    = balance * RiskPercent / 100.0;
   double tickValue  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize   = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);

   if(tickValue <= 0 || tickSize <= 0)
      return NormalizeLot(LotSize);

   double lot = riskAmt / (slDistance / tickSize * tickValue);
   return NormalizeLot(lot);
  }

//+------------------------------------------------------------------+
//| Place a pending breakout order for one session                   |
//+------------------------------------------------------------------+
void PlaceBreakoutOrders(SessionInfo &s)
  {
   // --- Pre-trade guards ---
   if(!IsSpreadOK())
     { Print(s.name, " skipped: spread too wide."); return; }

   if(MaxTrades > 0 && CountOpenPositions() >= MaxTrades)
     { Print(s.name, " skipped: max open trades (", MaxTrades, ") reached."); return; }

   if(IsDailyLossLimitReached())
     { Print(s.name, " skipped: daily loss limit reached."); return; }

   double point  = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   int    digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   int    mult   = PipMultiplier();

   // --- Range size filter ---
   double rangePips = (s.rangeHigh - s.rangeLow) / (mult * point);
   if(MinRangePips > 0 && rangePips < MinRangePips)
     { Print(s.name, " skipped: range too narrow (", rangePips, " pips < ", MinRangePips, ")."); return; }
   if(MaxRangePips > 0 && rangePips > MaxRangePips)
     { Print(s.name, " skipped: range too wide (", rangePips, " pips > ", MaxRangePips, "). Possible spike."); return; }

   double slDist  = StopLossPips   * mult * point;
   double tpDist  = TakeProfitPips * mult * point;
   int    htfBias = GetBias();
   int    rsiBias = GetRSIBias();

   // Both filters gate their respective directions independently.
   // A value of 0 means the filter is disabled → no restriction from that filter.
   bool buyAllowed  = (htfBias >= 0) && (rsiBias >= 0);
   bool sellAllowed = (htfBias <= 0) && (rsiBias <= 0);

   // Expiry datetime
   datetime expiry = 0;
   if(PendingOrderExpiry > 0)
      expiry = TimeCurrent() + PendingOrderExpiry * 60;

   double lot = CalculateLotSize(slDist);

   // --- BUY STOP ---
   if(buyAllowed)
     {
      double buyEntry = NormalizeDouble(s.rangeHigh + point, digits);
      double buySL    = NormalizeDouble(buyEntry - slDist, digits);
      double buyTP    = NormalizeDouble(buyEntry + tpDist, digits);

      if(trade.BuyStop(lot, buyEntry, _Symbol, buySL, buyTP,
                       ORDER_TIME_SPECIFIED, expiry, TradeComment))
        {
         s.buyStopTicket = trade.ResultOrder();
         Print(s.name, " BUY STOP placed at ", buyEntry, "  SL:", buySL, "  TP:", buyTP);
        }
      else
         Print("ERROR: BuyStop failed for ", s.name, ". Code: ", GetLastError());
     }

   // --- SELL STOP ---
   if(sellAllowed)
     {
      double sellEntry = NormalizeDouble(s.rangeLow - point, digits);
      double sellSL    = NormalizeDouble(sellEntry + slDist, digits);
      double sellTP    = NormalizeDouble(sellEntry - tpDist, digits);

      if(trade.SellStop(lot, sellEntry, _Symbol, sellSL, sellTP,
                        ORDER_TIME_SPECIFIED, expiry, TradeComment))
        {
         s.sellStopTicket = trade.ResultOrder();
         Print(s.name, " SELL STOP placed at ", sellEntry, "  SL:", sellSL, "  TP:", sellTP);
        }
      else
         Print("ERROR: SellStop failed for ", s.name, ". Code: ", GetLastError());
     }
  }

//+------------------------------------------------------------------+
//| Cancel a pending order by ticket if it still exists              |
//+------------------------------------------------------------------+
void CancelOrder(ulong &ticket)
  {
   if(ticket == 0)
      return;
   if(OrderSelect(ticket))
     {
      trade.OrderDelete(ticket);
      Print("Cancelled pending order #", ticket);
     }
   ticket = 0;
  }

//+------------------------------------------------------------------+
//| Cancel session pending orders at session close                   |
//+------------------------------------------------------------------+
void CancelSessionOrders(SessionInfo &s)
  {
   CancelOrder(s.buyStopTicket);
   CancelOrder(s.sellStopTicket);
  }

//+------------------------------------------------------------------+
//| Cancel the opposite pending order after one side is triggered    |
//+------------------------------------------------------------------+
void CheckAndCancelOpposite(SessionInfo &s)
  {
   if(!CancelOppositeOnFill)
      return;

   bool buyFilled  = WasOrderFilled(s.buyStopTicket);
   bool sellFilled = WasOrderFilled(s.sellStopTicket);

   if(buyFilled  && s.sellStopTicket != 0) CancelOrder(s.sellStopTicket);
   if(sellFilled && s.buyStopTicket  != 0) CancelOrder(s.buyStopTicket);
  }

//+------------------------------------------------------------------+
//| Build the breakout range (high/low of first N M15 candles)       |
//+------------------------------------------------------------------+
bool BuildRange(SessionInfo &s, datetime sessionStart)
  {
   double highs[], lows[];
   ArraySetAsSeries(highs, false);
   ArraySetAsSeries(lows,  false);

   // Find index of the bar at or just after session start
   int startIdx = iBarShift(_Symbol, PERIOD_M15, sessionStart, false);
   if(startIdx < 0)
     {
      Print("WARNING: iBarShift returned -1 for ", s.name, " session start. History not loaded?");
      return false;
     }

   int needed = BreakoutCandles;
   int gotH   = CopyHigh(_Symbol, PERIOD_M15, startIdx, needed, highs);
   int gotL   = CopyLow (_Symbol, PERIOD_M15, startIdx, needed, lows);
   if(gotH < needed || gotL < needed)
     {
      Print("WARNING: Insufficient M15 history for ", s.name,
            " (got ", MathMin(gotH, gotL), "/", needed, " bars). Skipping.");
      return false;
     }

   s.rangeHigh = highs[ArrayMaximum(highs)];
   s.rangeLow  = lows [ArrayMinimum(lows)];
   return true;
  }

//+------------------------------------------------------------------+
//| Draw or refresh session rectangle and range lines                |
//+------------------------------------------------------------------+
void RefreshSessionDraw(SessionInfo &s, datetime sessionStart, datetime sessionEnd)
  {
   string rectName  = "SB_rect_"  + s.name;
   string highName  = "SB_high_"  + s.name;
   string lowName   = "SB_low_"   + s.name;

   DrawSessionRect(rectName, sessionStart, sessionEnd, s.clr);

   if(s.rangeHigh > 0)
      DrawRangeLine(highName, s.rangeHigh, s.clr, STYLE_SOLID);
   if(s.rangeLow > 0)
      DrawRangeLine(lowName,  s.rangeLow,  s.clr, STYLE_DOT);
  }

//+------------------------------------------------------------------+
//| Compute datetime for today's session open based on server time   |
//+------------------------------------------------------------------+
datetime TodaySessionOpen(const SessionInfo &s)
  {
   MqlDateTime now;
   TimeToStruct(TimeCurrent(), now);
   now.hour = s.openHour;
   now.min  = s.openMin;
   now.sec  = 0;
   return StructToTime(now);
  }

datetime TodaySessionClose(const SessionInfo &s)
  {
   MqlDateTime now;
   TimeToStruct(TimeCurrent(), now);
   now.hour = s.closeHour;
   now.min  = s.closeMin;
   now.sec  = 0;
   datetime t = StructToTime(now);
   // If close < open (overnight session) push close to tomorrow
   datetime open = TodaySessionOpen(s);
   if(t < open)
      t += 86400;
   return t;
  }

//+------------------------------------------------------------------+
//| Move SL to break-even for all EA positions when profit >= target |
//+------------------------------------------------------------------+
void ManageBreakEven()
  {
   if(!UseBreakEven)
      return;

   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   int    mult  = PipMultiplier();
   double bePips = BreakEvenAtPips    * mult * point;
   double extra  = BreakEvenExtraPips * mult * point;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket))                   continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)     continue;
      if(PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;

      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      double currentSL = PositionGetDouble(POSITION_SL);
      double currentTP = PositionGetDouble(POSITION_TP);
      ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);

      if(posType == POSITION_TYPE_BUY)
        {
         double bid  = SymbolInfoDouble(_Symbol, SYMBOL_BID);
         double beSL = NormalizeDouble(openPrice + extra, _Digits);
         // Only modify if profit target reached and SL hasn't already been moved to BE
         if(bid - openPrice >= bePips && currentSL < beSL && currentSL != beSL)
            trade.PositionModify(ticket, beSL, currentTP);
        }
      else if(posType == POSITION_TYPE_SELL)
        {
         double ask  = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         double beSL = NormalizeDouble(openPrice - extra, _Digits);
         // Only modify if profit target reached and SL hasn't already been moved to BE
         if(openPrice - ask >= bePips && currentSL > beSL && currentSL != beSL)
            trade.PositionModify(ticket, beSL, currentTP);
        }
     }
  }

//+------------------------------------------------------------------+
//| Trail stop loss for all open EA positions                        |
//+------------------------------------------------------------------+
void TrailOpenPositions()
  {
   if(!UseTrailingStop)
      return;

   double point      = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   int    mult       = PipMultiplier();
   double trailDist  = TrailingDistPips  * mult * point;
   double trailStart = TrailingStartPips * mult * point;
   double trailStep  = TrailingStepPips  * mult * point;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket))                   continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)     continue;
      if(PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;

      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      double currentSL = PositionGetDouble(POSITION_SL);
      double currentTP = PositionGetDouble(POSITION_TP);
      ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);

      if(posType == POSITION_TYPE_BUY)
        {
         double bid   = SymbolInfoDouble(_Symbol, SYMBOL_BID);
         if(bid - openPrice < trailStart)
            continue;
         double newSL = NormalizeDouble(bid - trailDist, _Digits);
         // Only move SL upward and only when improvement >= minimum step
         if(newSL >= currentSL + trailStep)
            trade.PositionModify(ticket, newSL, currentTP);
        }
      else if(posType == POSITION_TYPE_SELL)
        {
         double ask   = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         if(openPrice - ask < trailStart)
            continue;
         double newSL = NormalizeDouble(ask + trailDist, _Digits);
         // Only move SL downward and only when improvement >= minimum step
         if(newSL <= currentSL - trailStep)
            trade.PositionModify(ticket, newSL, currentTP);
        }
     }
  }

//+------------------------------------------------------------------+
//| Expert initialisation                                            |
//+------------------------------------------------------------------+
int OnInit()
  {
   InitSessions();

   if(UseBiasFilter)
     {
      biasEMAHandle = iMA(_Symbol, BiasTF, BiasEMAPeriod, 0, MODE_EMA, PRICE_CLOSE);
      if(biasEMAHandle == INVALID_HANDLE)
        {
         Print("WARNING: Could not create bias EMA handle. Bias filter disabled.");
        }
     }

   if(UseRSIFilter)
     {
      rsiHandle = iRSI(_Symbol, RSITimeframe, RSIPeriod, PRICE_CLOSE);
      if(rsiHandle == INVALID_HANDLE)
         Print("WARNING: Could not create RSI handle. RSI filter disabled.");
     }

   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(SlippagePoints);
   trade.SetTypeFilling(FillType);

   // Initialise daily loss tracking
   dailyStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   dt.hour = 0; dt.min = 0; dt.sec = 0;
   lastDayChecked = StructToTime(dt);

   // Recover pending order tickets that existed before an EA restart
   RestoreSessionTickets();

   Print("SessionBreakoutEA v2 initialized on ", _Symbol, " / ", EnumToString(_Period));
   return INIT_SUCCEEDED;
  }

//+------------------------------------------------------------------+
//| Expert deinitialization                                          |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   if(biasEMAHandle != INVALID_HANDLE) IndicatorRelease(biasEMAHandle);
   if(rsiHandle     != INVALID_HANDLE) IndicatorRelease(rsiHandle);

   // Clean up chart objects created by this EA
   for(int i = 0; i < 4; i++)
     {
      ObjectDelete(0, "SB_rect_" + sessions[i].name);
      ObjectDelete(0, "SB_high_" + sessions[i].name);
      ObjectDelete(0, "SB_low_"  + sessions[i].name);
     }
   ChartRedraw(0);
  }

//+------------------------------------------------------------------+
//| Main tick handler                                                |
//+------------------------------------------------------------------+
void OnTick()
  {
   datetime now = TimeCurrent();

   // Update daily loss tracking (resets at midnight)
   CheckResetDailyBalance();

   // Trailing stop and break-even management run every tick
   TrailOpenPositions();
   ManageBreakEven();

   if(IsNewsWindow(now))
      return;

   // Guard: stop opening new positions if daily drawdown limit is breached
   if(IsDailyLossLimitReached())
     {
      static datetime lastLimitWarn = 0;
      if(now - lastLimitWarn > 3600)
        {
         Print("Daily loss limit reached. No new trades until tomorrow.");
         lastLimitWarn = now;
        }
      return;
     }

   MqlDateTime dt;
   TimeToStruct(now, dt);
   int curH = dt.hour;
   int curM = dt.min;

   for(int i = 0; i < 4; i++)
     {
      SessionInfo &s = sessions[i];
      bool inSession = IsInSession(s, curH, curM);

      // ---- Session just opened: build range after BreakoutCandles M15 bars ----
      if(inSession)
        {
         datetime sessionStart = TodaySessionOpen(s);
         datetime sessionEnd   = TodaySessionClose(s);
         datetime rangeEnd     = sessionStart + (datetime)(BreakoutCandles * 15 * 60);

         // Draw session background every tick (handles chart scrolling)
         RefreshSessionDraw(s, sessionStart, sessionEnd);

         // Build range and place orders once per session
         if(s.lastSetupTime != sessionStart && now >= rangeEnd)
           {
            s.lastSetupTime    = sessionStart;
            s.buyStopTicket    = 0;
            s.sellStopTicket   = 0;

            if(BuildRange(s, sessionStart))
              {
               RefreshSessionDraw(s, sessionStart, sessionEnd); // update lines
               PlaceBreakoutOrders(s);
              }
            else
               Print("WARNING: Could not build range for ", s.name, " session.");
           }

         // Check if one side was filled → cancel the other
         CheckAndCancelOpposite(s);
        }
      else
        {
         // Session closed: cancel any unfilled pending orders
         if(s.buyStopTicket != 0 || s.sellStopTicket != 0)
           {
            Print(s.name, " session ended. Cancelling remaining pending orders.");
            CancelSessionOrders(s);
           }
         s.isActive = false;
        }
     }

   ChartRedraw(0);
  }
//+------------------------------------------------------------------+
