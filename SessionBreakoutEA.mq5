//+------------------------------------------------------------------+
//|                                          SessionBreakoutEA.mq5   |
//|              Session First-15-Min Candle Breakout Expert Advisor |
//|                                                                  |
//| Strategy:                                                        |
//|  1. At the start of each configured session, record the HIGH     |
//|     and LOW of the first 15-minute candle (the "breakout range") |
//|  2. Place a BUY STOP above the range high and a SELL STOP below  |
//|     the range low                                                |
//|  3. When one side is triggered, cancel the other                 |
//|  4. Optional bias filter: only take buys when price is above     |
//|     the 200 EMA on a higher timeframe (and vice versa for sells) |
//|  5. Market sessions are drawn as coloured background bands       |
//|                                                                  |
//| Designed for XAU/USD (GOLD) but works on any symbol.            |
//+------------------------------------------------------------------+
#property copyright "Copyright 2024"
#property version   "1.00"
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
int        biasEMAHandle = INVALID_HANDLE;

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
   double point  = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   int    digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   int    mult   = PipMultiplier();
   double slDist = StopLossPips   * mult * point;
   double tpDist = TakeProfitPips * mult * point;
   int    bias   = GetBias();

   // Expiry datetime
   datetime expiry = 0;
   if(PendingOrderExpiry > 0)
      expiry = TimeCurrent() + PendingOrderExpiry * 60;

   double lot = CalculateLotSize(slDist);

   // --- BUY STOP ---
   if(bias >= 0) // allow buy when bullish or no filter
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
   if(bias <= 0) // allow sell when bearish or no filter
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

   // If buy stop has been triggered (position opened), cancel sell stop
   bool buyFilled  = (s.buyStopTicket  != 0 && !OrderSelect(s.buyStopTicket));
   bool sellFilled = (s.sellStopTicket != 0 && !OrderSelect(s.sellStopTicket));

   if(buyFilled  && s.sellStopTicket != 0) CancelOrder(s.sellStopTicket);
   if(sellFilled && s.buyStopTicket  != 0) CancelOrder(s.buyStopTicket);
  }

//+------------------------------------------------------------------+
//| Build the breakout range (high/low of first N M15 candles)       |
//+------------------------------------------------------------------+
bool BuildRange(SessionInfo &s, datetime sessionStart)
  {
   // Get M15 bars from sessionStart
   datetime barTimes[];
   double   highs[], lows[];
   ArraySetAsSeries(barTimes, false);
   ArraySetAsSeries(highs,    false);
   ArraySetAsSeries(lows,     false);

   // Find index of the bar at or just after session start
   int startIdx = iBarShift(_Symbol, PERIOD_M15, sessionStart, false);
   if(startIdx < 0)
      return false;

   // We need BreakoutCandles bars starting from startIdx
   // CopyHigh/CopyLow with start position (oldest first)
   int needed = BreakoutCandles;
   if(CopyHigh(_Symbol, PERIOD_M15, startIdx, needed, highs) < needed)
      return false;
   if(CopyLow (_Symbol, PERIOD_M15, startIdx, needed, lows)  < needed)
      return false;

   double hi = highs[ArrayMaximum(highs)];
   double lo = lows [ArrayMinimum(lows)];

   s.rangeHigh = hi;
   s.rangeLow  = lo;
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

   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(SlippagePoints);
   trade.SetTypeFilling(FillType);

   Print("SessionBreakoutEA initialized on ", _Symbol, " / ", EnumToString(_Period));
   return INIT_SUCCEEDED;
  }

//+------------------------------------------------------------------+
//| Expert deinitialization                                          |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   if(biasEMAHandle != INVALID_HANDLE)
      IndicatorRelease(biasEMAHandle);

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

   if(IsNewsWindow(now))
      return;

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
