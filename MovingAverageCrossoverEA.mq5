//+------------------------------------------------------------------+
//|                                   MovingAverageCrossoverEA.mq5   |
//|                        Moving Average Crossover Expert Advisor    |
//|                                                                  |
//| Strategy:                                                        |
//|   - Buy  when the fast MA crosses above the slow MA              |
//|   - Sell when the fast MA crosses below the slow MA              |
//|   - Each trade is protected by a Stop Loss and Take Profit       |
//+------------------------------------------------------------------+
#property copyright "Copyright 2024"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>

//--- Input parameters
input group "Moving Average Settings"
input int    FastMAPeriod   = 9;                  // Fast MA period
input int    SlowMAPeriod   = 21;                 // Slow MA period
input ENUM_MA_METHOD MAMethod = MODE_EMA;         // MA method (SMA, EMA, SMMA, LWMA)
input ENUM_APPLIED_PRICE AppliedPrice = PRICE_CLOSE; // Applied price

input group "Trade Settings"
input double LotSize        = 0.1;                // Lot size
input int    StopLossPips   = 50;                 // Stop loss (in pips)
input int    TakeProfitPips = 100;                // Take profit (in pips)
input int    MagicNumber    = 123456;             // Magic number (unique EA identifier)
input string TradeComment   = "MA_Crossover_EA";  // Trade comment
input int    SlippagePoints = 10;                 // Max slippage (in points)
input ENUM_ORDER_TYPE_FILLING FillType = ORDER_FILLING_RETURN; // Order filling type (RETURN is most broker-compatible)

input group "Risk Management"
input bool   UseMoneyManagement = false;          // Enable dynamic lot sizing
input double RiskPercent        = 1.0;            // Risk per trade (% of balance)

//--- Global variables
CTrade trade;
int    fastMAHandle;
int    slowMAHandle;
double fastMABuffer[];
double slowMABuffer[];

//+------------------------------------------------------------------+
//| Expert initialisation function                                   |
//+------------------------------------------------------------------+
int OnInit()
  {
   // Validate inputs
   if(FastMAPeriod <= 0 || SlowMAPeriod <= 0)
     {
      Print("ERROR: MA periods must be greater than 0.");
      return INIT_PARAMETERS_INCORRECT;
     }
   if(FastMAPeriod >= SlowMAPeriod)
     {
      Print("ERROR: FastMAPeriod must be less than SlowMAPeriod.");
      return INIT_PARAMETERS_INCORRECT;
     }
   if(LotSize <= 0)
     {
      Print("ERROR: LotSize must be greater than 0.");
      return INIT_PARAMETERS_INCORRECT;
     }

   // Create indicator handles
   fastMAHandle = iMA(_Symbol, _Period, FastMAPeriod, 0, MAMethod, AppliedPrice);
   slowMAHandle = iMA(_Symbol, _Period, SlowMAPeriod, 0, MAMethod, AppliedPrice);

   if(fastMAHandle == INVALID_HANDLE || slowMAHandle == INVALID_HANDLE)
     {
      Print("ERROR: Failed to create MA indicator handles.");
      return INIT_FAILED;
     }

   // Set buffer as series (index 0 = most recent bar)
   ArraySetAsSeries(fastMABuffer, true);
   ArraySetAsSeries(slowMABuffer, true);

   // Configure the trade object
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(SlippagePoints);
   trade.SetTypeFilling(FillType);

   Print("MovingAverageCrossoverEA initialized. Symbol: ", _Symbol,
         "  Fast MA: ", FastMAPeriod, "  Slow MA: ", SlowMAPeriod);
   return INIT_SUCCEEDED;
  }

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   IndicatorRelease(fastMAHandle);
   IndicatorRelease(slowMAHandle);
   Print("MovingAverageCrossoverEA deinitialized. Reason code: ", reason);
  }

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
  {
   // Only act on a new bar to avoid multiple signals per bar
   if(!IsNewBar())
      return;

   // Copy the two most recent MA values (index 0 = current, index 1 = previous)
   if(CopyBuffer(fastMAHandle, 0, 0, 2, fastMABuffer) < 2 ||
      CopyBuffer(slowMAHandle, 0, 0, 2, slowMABuffer) < 2)
     {
      Print("WARNING: Not enough MA data yet.");
      return;
     }

   double fastCurrent  = fastMABuffer[0];
   double fastPrevious = fastMABuffer[1];
   double slowCurrent  = slowMABuffer[0];
   double slowPrevious = slowMABuffer[1];

   bool bullishCross = (fastPrevious <= slowPrevious) && (fastCurrent > slowCurrent);
   bool bearishCross = (fastPrevious >= slowPrevious) && (fastCurrent < slowCurrent);

   // Close opposing positions before opening a new one
   if(bullishCross && HasOpenPosition(POSITION_TYPE_SELL))
      ClosePositions(POSITION_TYPE_SELL);

   if(bearishCross && HasOpenPosition(POSITION_TYPE_BUY))
      ClosePositions(POSITION_TYPE_BUY);

   // Open new position if none exists in the signal direction
   if(bullishCross && !HasOpenPosition(POSITION_TYPE_BUY))
      OpenBuy();

   if(bearishCross && !HasOpenPosition(POSITION_TYPE_SELL))
      OpenSell();
  }

//+------------------------------------------------------------------+
//| Return the point-to-pip multiplier for the current symbol        |
//| Most brokers use 5-digit FX quotes (1 pip = 10 points).          |
//| 2/3-digit symbols (e.g. JPY pairs, indices) use 1 point per pip. |
//+------------------------------------------------------------------+
int PipMultiplier()
  {
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   return (digits == 3 || digits == 5) ? 10 : 1;
  }

//+------------------------------------------------------------------+
//| Open a BUY position                                              |
//+------------------------------------------------------------------+
void OpenBuy()
  {
   double ask    = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double point  = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   int    digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   int    mult   = PipMultiplier();

   double sl  = NormalizeDouble(ask - StopLossPips   * mult * point, digits);
   double tp  = NormalizeDouble(ask + TakeProfitPips * mult * point, digits);
   double lot = CalculateLotSize(StopLossPips * mult * point);

   if(!trade.Buy(lot, _Symbol, ask, sl, tp, TradeComment))
      Print("ERROR: Buy order failed. Code: ", GetLastError());
   else
      Print("BUY opened. Lot: ", lot, "  SL: ", sl, "  TP: ", tp);
  }

//+------------------------------------------------------------------+
//| Open a SELL position                                             |
//+------------------------------------------------------------------+
void OpenSell()
  {
   double bid    = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double point  = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   int    digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   int    mult   = PipMultiplier();

   double sl  = NormalizeDouble(bid + StopLossPips   * mult * point, digits);
   double tp  = NormalizeDouble(bid - TakeProfitPips * mult * point, digits);
   double lot = CalculateLotSize(StopLossPips * mult * point);

   if(!trade.Sell(lot, _Symbol, bid, sl, tp, TradeComment))
      Print("ERROR: Sell order failed. Code: ", GetLastError());
   else
      Print("SELL opened. Lot: ", lot, "  SL: ", sl, "  TP: ", tp);
  }

//+------------------------------------------------------------------+
//| Check whether a position of the given type is already open       |
//+------------------------------------------------------------------+
bool HasOpenPosition(ENUM_POSITION_TYPE posType)
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(PositionSelectByTicket(PositionGetTicket(i)))
        {
         if(PositionGetInteger(POSITION_MAGIC)  == MagicNumber &&
            PositionGetString(POSITION_SYMBOL) == _Symbol     &&
            (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) == posType)
            return true;
        }
     }
   return false;
  }

//+------------------------------------------------------------------+
//| Close all positions of the given type                            |
//+------------------------------------------------------------------+
void ClosePositions(ENUM_POSITION_TYPE posType)
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(PositionSelectByTicket(ticket))
        {
         if(PositionGetInteger(POSITION_MAGIC)  == MagicNumber &&
            PositionGetString(POSITION_SYMBOL) == _Symbol     &&
            (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) == posType)
           {
            if(!trade.PositionClose(ticket))
               Print("ERROR: Could not close position #", ticket, ". Code: ", GetLastError());
           }
        }
     }
  }

//+------------------------------------------------------------------+
//| Calculate lot size (fixed or risk-based)                         |
//+------------------------------------------------------------------+
double CalculateLotSize(double slDistance)
  {
   if(!UseMoneyManagement || slDistance <= 0)
      return NormalizeLot(LotSize);

   double balance     = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskAmount  = balance * RiskPercent / 100.0;
   double tickValue   = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize    = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);

   if(tickValue <= 0 || tickSize <= 0)
      return NormalizeLot(LotSize);

   double lot = riskAmount / (slDistance / tickSize * tickValue);
   return NormalizeLot(lot);
  }

//+------------------------------------------------------------------+
//| Normalize lot size to broker constraints                         |
//+------------------------------------------------------------------+
double NormalizeLot(double lot)
  {
   double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   lot = MathFloor(lot / lotStep) * lotStep;
   lot = MathMax(minLot, MathMin(maxLot, lot));

   // Derive decimal precision from the lot step (e.g. step 0.01 → 2 decimals)
   int decimals = (int)MathRound(-MathLog10(lotStep));
   decimals = MathMax(0, decimals);
   return NormalizeDouble(lot, decimals);
  }

//+------------------------------------------------------------------+
//| Detect the start of a new bar                                    |
//+------------------------------------------------------------------+
bool IsNewBar()
  {
   static datetime lastBarTime = 0;
   datetime currentBarTime = (datetime)SeriesInfoInteger(_Symbol, _Period, SERIES_LASTBAR_DATE);

   if(currentBarTime != lastBarTime)
     {
      lastBarTime = currentBarTime;
      return true;
     }
   return false;
  }
//+------------------------------------------------------------------+
