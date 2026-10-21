//+------------------------------------------------------------------+
//|                                                      Gold X9 strategy |
//|                                      Copyright 2020, Rbot.cc |
//|                                       https://rbot.cc |
//+------------------------------------------------------------------+
#property strict
#property version   "1.00"
#property description "A MetaTrader 5 (MT5) Expert Advisor based on breakouts of prior swing highs and lows"
#property copyright "Rbot.cc"
#property link "https://rbot.cc"

#include <Trade/Trade.mqh>

enum LotMode { LOT_FIXED=0, LOT_RISK_PERCENT=1 };

input group "Trade setup"
input ulong   InpMagic                 = 900009; // Expert magic number
input string  InpComment               = "GoldX9 strategy 9"; // Order comment
input LotMode InpLotMode               = LOT_FIXED; // Position sizing mode
input double  InpFixedLots             = 0.01; // Fixed lot size
input double  InpRiskPercent           = 0.50; // Risk per order (% of equity)
input int     InpMaxPending            = 3; // Maximum pending orders per direction
input int     InpMaxPositions          = 10; // Maximum open positions
input int     InpPendingExpiryHours    = 15; // Pending expiry input (hours; orders use GTC)
input int     InpDuplicatePoints       = 100; // Minimum pending order separation (points)

input group "Structure"
const ENUM_TIMEFRAMES InpFractalTF     = PERIOD_H1; // Fixed H1 data timeframe, independent of chart or tester period
input int     InpRescanMinutes         = 15; // Structure rescan interval (minutes)
input int     InpFractalLeft           = 5; // Older bars required for a swing
input int     InpFractalRight          = 5; // Newer bars required for a swing
input int     InpMaxSearchBars         = 200; // Maximum swing search depth (bars)
input double  InpMinFractalClearancePct= 0.02; // Minimum market clearance from swing (%)

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
input group "Entry and exits (percent of price)"
input double  InpBuyEntryOffsetPct     = -0.10; // Buy entry offset from swing high (%)
input double  InpSellEntryOffsetPct    = -0.10; // Sell entry offset subtracted from swing low (%)
input double  InpStopLossPct           = 2.00; // Initial stop loss distance (%)
input double  InpTakeProfitPct         = 1.00; // Initial take profit distance (%)
input double  InpTrailTriggerPct       = 0.20; // Trailing stop activation gain (%)
input double  InpTrailDistancePct      = 0.20; // Trailing distance from current price (%)
input double  InpMaxTrailPct           = 1.00; // Maximum gain for trailing updates (%)
input double  InpSalvageTriggerPct     = 1.00; // Loss threshold for salvage target (%)
input double  InpSalvageExitPct        = 0.15; // Salvage target loss from entry (%)
input double  InpBreakEvenTriggerPct   = 0.10; // Break-even activation gain (%)
input double  InpBreakEvenLockPct      = 0.025; // Profit locked at break-even (%)

CTrade trade;
datetime g_last_scan=0;
double g_point, g_tick_size, g_tick_value;
int g_digits;

//+------------------------------------------------------------------+
//| Convert a percentage of price to a price distance                |
//+------------------------------------------------------------------+
double Pct(double price,double pct) { return price*pct/100.0; }
//+------------------------------------------------------------------+
//| Normalize a price to the symbol digits                           |
//+------------------------------------------------------------------+
double N(double price) { return NormalizeDouble(g_tick_size>0 ? MathRound(price/g_tick_size)*g_tick_size : price,g_digits); }

//+------------------------------------------------------------------+
//| Check whether an order belongs to this EA                        |
//+------------------------------------------------------------------+
bool OurOrder(ulong ticket)
  {
//--- Select the order and check ownership
   if(!OrderSelect(ticket))
      return false;
   return (OrderGetString(ORDER_SYMBOL)==_Symbol &&
           (ulong)OrderGetInteger(ORDER_MAGIC)==InpMagic);
  }
//+------------------------------------------------------------------+
//| Check whether a position belongs to this EA                      |
//+------------------------------------------------------------------+
bool OurPosition(ulong ticket)
  {
//--- Select the position and check ownership
   if(!PositionSelectByTicket(ticket))
      return false;
   return (PositionGetString(POSITION_SYMBOL)==_Symbol &&
           (ulong)PositionGetInteger(POSITION_MAGIC)==InpMagic);
  }

//+------------------------------------------------------------------+
//| Count open positions belonging to this EA                        |
//+------------------------------------------------------------------+
int CountPositions()
  {
//--- Count matching orders or positions
   int n=0;
//--- Inspect open positions
   for(int i=PositionsTotal()-1;i>=0;i--)
      if(OurPosition(PositionGetTicket(i)))
         n++;
   return n;
  }
//+------------------------------------------------------------------+
//| Count pending orders of the requested type                       |
//+------------------------------------------------------------------+
int CountPending(ENUM_ORDER_TYPE type)
  {
//--- Count matching orders or positions
   int n=0;
//--- Inspect pending orders
   for(int i=OrdersTotal()-1;i>=0;i--)
     {
      ulong t=OrderGetTicket(i);
      if(OurOrder(t) && (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE)==type)
         n++;
     }
   return n;
  }

//+------------------------------------------------------------------+
//| Normalize volume using current symbol limits and step            |
//+------------------------------------------------------------------+
double NormalizeVolume(double requested)
  {
   //--- Reject invalid requests or unavailable symbol specifications
   double vmin=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
   double vmax=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX);
   double step=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);
   if(!MathIsValidNumber(requested) || requested<=0 ||
      vmin<=0 || vmax<vmin || step<=0)
      return 0;
   //--- Derive decimal precision from the step, including 0.001 lots
   int digits=0;
   while(digits<8 && MathAbs(step-NormalizeDouble(step,digits))>1e-10)
      digits++;
   //--- Clamp and round down on the broker volume-step grid
   double bounded=MathMax(vmin,MathMin(vmax,requested));
   double lots=NormalizeDouble(MathFloor(bounded/step+1e-9)*step,digits);
   if(lots<vmin-1e-9)
      lots=NormalizeDouble(MathCeil(vmin/step-1e-9)*step,digits);
   if(lots>vmax+1e-9 || lots<vmin-1e-9)
      return 0;
   return lots;
  }

//+------------------------------------------------------------------+
//| Calculate volume using the selected sizing mode                  |
//+------------------------------------------------------------------+
double LotsForRisk(double entry,double sl)
  {
   //--- Normalize fixed lots and the fallback through the same path
   if(InpLotMode==LOT_FIXED)
      return NormalizeVolume(InpFixedLots);
   double risk_money=AccountInfoDouble(ACCOUNT_EQUITY)*InpRiskPercent/100.0;
   double distance=MathAbs(entry-sl);
   if(distance<=0 || g_tick_size<=0 || g_tick_value<=0)
      return NormalizeVolume(InpFixedLots);
   //--- Estimate risk volume and apply current broker specifications
   return NormalizeVolume(risk_money/(distance/g_tick_size*g_tick_value));
  }

//+------------------------------------------------------------------+
//| Enforce the symbol-wide directional position and order limit     |
//+------------------------------------------------------------------+
double LimitDirectionalVolume(bool buy,double requested)
  {
   double limit=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_LIMIT);
   if(limit<=0)
      return requested;
   //--- Count all trades on the symbol, including other magic numbers
   double used=0;
   for(int i=PositionsTotal()-1;i>=0;i--)
     {
      if(PositionGetTicket(i)==0 || PositionGetString(POSITION_SYMBOL)!=_Symbol)
         continue;
      if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE)==
         (buy?POSITION_TYPE_BUY:POSITION_TYPE_SELL))
         used+=PositionGetDouble(POSITION_VOLUME);
     }
   for(int i=OrdersTotal()-1;i>=0;i--)
     {
      if(OrderGetTicket(i)==0 || OrderGetString(ORDER_SYMBOL)!=_Symbol)
         continue;
      ENUM_ORDER_TYPE type=(ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      bool same=buy ? (type==ORDER_TYPE_BUY_LIMIT || type==ORDER_TYPE_BUY_STOP || type==ORDER_TYPE_BUY_STOP_LIMIT)
                    : (type==ORDER_TYPE_SELL_LIMIT || type==ORDER_TYPE_SELL_STOP || type==ORDER_TYPE_SELL_STOP_LIMIT);
      if(same)
         used+=OrderGetDouble(ORDER_VOLUME_CURRENT);
     }
   //--- Do not raise residual capacity to the minimum trading volume
   double available=MathMax(0,limit-used);
   if(available+1e-9<SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN))
      return 0;
   double lots=NormalizeVolume(MathMin(requested,available));
   return lots<=available+1e-9 ? lots : 0;
  }

//+------------------------------------------------------------------+
//| Check a swing high against neighboring bars                      |
//+------------------------------------------------------------------+
bool IsSwingHigh(const MqlRates &r[],int i)
  {
//--- Compare the candidate with older bars
   for(int k=1;k<=InpFractalLeft;k++)
      if(r[i].high<=r[i+k].high)
         return false;
//--- Compare the candidate with newer bars
   for(int k=1;k<=InpFractalRight;k++)
      if(r[i].high<=r[i-k].high)
         return false;
   return true;
  }
//+------------------------------------------------------------------+
//| Check a swing low against neighboring bars                       |
//+------------------------------------------------------------------+
bool IsSwingLow(const MqlRates &r[],int i)
  {
//--- Compare the candidate with older bars
   for(int k=1;k<=InpFractalLeft;k++)
      if(r[i].low>=r[i+k].low)
         return false;
//--- Compare the candidate with newer bars
   for(int k=1;k<=InpFractalRight;k++)
      if(r[i].low>=r[i-k].low)
         return false;
   return true;
  }

//+------------------------------------------------------------------+
//| Find the most recent confirmed swing level                       |
//+------------------------------------------------------------------+
double FindSwing(bool high)
  {
//--- Load price bars for the swing search
   MqlRates r[];
   ArraySetAsSeries(r,true);
   int need=InpMaxSearchBars+InpFractalLeft+InpFractalRight+5;
   if(CopyRates(_Symbol,InpFractalTF,0,need,r)<need)
      return 0;
//--- Skip unconfirmed candidates and search newest to oldest
   int first=InpFractalRight+1;
   int last=MathMin(InpMaxSearchBars,ArraySize(r)-InpFractalLeft-1);
   for(int i=first;i<=last;i++)
      if(high ? IsSwingHigh(r,i) : IsSwingLow(r,i))
         return high?r[i].high:r[i].low;
   return 0;
  }

//+------------------------------------------------------------------+
//| Check for a nearby pending order of the same type                |
//+------------------------------------------------------------------+
bool SimilarPending(ENUM_ORDER_TYPE type,double price)
  {
//--- Inspect pending orders
   for(int i=OrdersTotal()-1;i>=0;i--)
     {
      ulong t=OrderGetTicket(i);
      if(OurOrder(t) && (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE)==type)
         if(MathAbs(OrderGetDouble(ORDER_PRICE_OPEN)-price)<=InpDuplicatePoints*g_point)
            return true;
     }
   return false;
  }

//+------------------------------------------------------------------+
//| Check server-time sessions, including overnight trading           |
//+------------------------------------------------------------------+
bool TradingSessionOpen()
  {
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(),dt);
   int seconds=dt.hour*3600+dt.min*60+dt.sec;
   //--- Include yesterday's overnight remainder
   for(int back=0;back<=1;back++)
      for(uint index=0;index<32;index++)
        {
         datetime from,to;
         if(!SymbolInfoSessionTrade(_Symbol,(ENUM_DAY_OF_WEEK)((dt.day_of_week+7-back)%7),index,from,to)) break;
         int start=(int)((long)from%86400),end=(int)((long)to%86400);
         if(back==0 && ((long)to-(long)from>=86400 || start==end)) return true;
         if(end>start && back==0 && seconds>=start && seconds<end) return true;
         if(end<start && ((back==0 && seconds>=start) || (back==1 && seconds<end))) return true;
        }
   return false;
  }

//+------------------------------------------------------------------+
//| Reserve estimated activation margin for all pending orders        |
//+------------------------------------------------------------------+
double PendingMarginReserve()
  {
   double total=0;
   //--- Include other symbols and magic numbers, without netting relief
   for(int i=OrdersTotal()-1;i>=0;i--)
     {
      if(OrderGetTicket(i)==0) continue;
      ENUM_ORDER_TYPE type=(ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      bool buy=(type==ORDER_TYPE_BUY_LIMIT || type==ORDER_TYPE_BUY_STOP || type==ORDER_TYPE_BUY_STOP_LIMIT);
      bool sell=(type==ORDER_TYPE_SELL_LIMIT || type==ORDER_TYPE_SELL_STOP || type==ORDER_TYPE_SELL_STOP_LIMIT);
      if(!buy && !sell) continue;
      double margin=0;
      if(!OrderCalcMargin(buy?ORDER_TYPE_BUY:ORDER_TYPE_SELL,OrderGetString(ORDER_SYMBOL),
                          OrderGetDouble(ORDER_VOLUME_CURRENT),OrderGetDouble(ORDER_PRICE_OPEN),margin)) return DBL_MAX;
      total+=margin;
     }
   return total;
  }

//+------------------------------------------------------------------+
//| Reject unaffordable orders without reducing the requested volume   |
//+------------------------------------------------------------------+
double AffordableVolume(bool buy,double entry,double requested)
  {
   if(requested<=0) return 0;
   //--- Reserve existing pending activations and keep a 20 percent buffer
   double free_margin=AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   double reserved=PendingMarginReserve();
   double budget=MathMax(0,free_margin*0.80)-reserved;
   double margin=0;
   ResetLastError();
   if(!OrderCalcMargin(buy?ORDER_TYPE_BUY:ORDER_TYPE_SELL,_Symbol,requested,entry,margin))
     {
      PrintFormat("Pending skipped: margin calculation failed; symbol=%s lots=%.8f entry=%s error=%d",
                  _Symbol,requested,DoubleToString(entry,g_digits),GetLastError());
      return 0;
     }
   //--- Skip the entire order rather than silently lowering its lot size
   if(!MathIsValidNumber(margin) || margin<0 || budget<=0 || margin>budget)
     {
      PrintFormat("Pending skipped: insufficient margin budget; symbol=%s type=%s lots=%.8f required=%.2f free=%.2f pending_reserved=%.2f budget=%.2f",
                  _Symbol,buy?"BUY_STOP":"SELL_STOP",requested,margin,free_margin,reserved,budget);
      return 0;
     }
   return requested;
  }

//+------------------------------------------------------------------+
//| Remove owned unfrozen pending orders when margin deteriorates      |
//+------------------------------------------------------------------+
void ReviewPendingMargin()
  {
   for(int i=OrdersTotal()-1;i>=0;i--)
     {
      if(PendingMarginReserve()<=MathMax(0,AccountInfoDouble(ACCOUNT_MARGIN_FREE)*0.80)) break;
      ulong ticket=OrderGetTicket(i);
      if(!OurOrder(ticket)) continue;
      ENUM_ORDER_TYPE type=(ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      if(type!=ORDER_TYPE_BUY_STOP && type!=ORDER_TYPE_SELL_STOP) continue;
      MqlTick tick;
      if(!SymbolInfoTick(_Symbol,tick)) continue;
      double quote=type==ORDER_TYPE_BUY_STOP?tick.ask:tick.bid;
      double freeze=SymbolInfoInteger(_Symbol,SYMBOL_TRADE_FREEZE_LEVEL)*g_point;
      if(MathAbs(OrderGetDouble(ORDER_PRICE_OPEN)-quote)<=freeze+MathMax(g_tick_size,g_point)) continue;
      //--- Never close positions or delete other EAs' orders
      bool ok=trade.OrderDelete(ticket);
      PrintFormat("Margin reserve cleanup: order=%I64u call_ok=%s retcode=%u description=%s",
                  ticket,ok?"true":"false",trade.ResultRetcode(),trade.ResultRetcodeDescription());
     }
  }

//+------------------------------------------------------------------+
//| Precheck all pending request parameters before submission          |
//+------------------------------------------------------------------+
bool CheckPendingRequest(ENUM_ORDER_TYPE type,double lots,double entry,double sl,double tp,datetime expiry)
  {
   MqlTradeRequest request={};
   MqlTradeCheckResult result={};
   request.action=TRADE_ACTION_PENDING;
   request.symbol=_Symbol;
   request.magic=InpMagic;
   request.type=type;
   request.volume=lots;
   request.price=entry;
   request.sl=sl;
   request.tp=tp;
   request.type_time=ORDER_TIME_GTC;
   request.type_filling=ORDER_FILLING_RETURN;
   request.expiration=expiry;
   request.comment=InpComment;
   if(!OrderCheck(request,result) || (result.retcode!=0 && result.retcode!=TRADE_RETCODE_DONE))
     {
      PrintFormat("Pending precheck rejected: retcode=%u comment=%s free_margin=%.2f",
                  result.retcode,result.comment,result.margin_free);
      return false;
     }
   return true;
  }

//+------------------------------------------------------------------+
//| Validate existing freeze zones and new protective distances        |
//+------------------------------------------------------------------+
bool CanModifyPosition(long type,double sl,double tp,double next_sl,double next_tp,double quote)
  {
   double freeze=SymbolInfoInteger(_Symbol,SYMBOL_TRADE_FREEZE_LEVEL)*g_point;
   double buffer=MathMax(g_tick_size,g_point);
   //--- Existing SL or TP in the freeze zone blocks the whole request
   if(freeze>0 && ((sl>0 && MathAbs(quote-sl)<=freeze+buffer) ||
                  (tp>0 && MathAbs(quote-tp)<=freeze+buffer))) return false;
   double distance=MathMax(freeze,SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL)*g_point)+buffer;
   if(type==POSITION_TYPE_BUY)
      return (next_sl==0 || quote-next_sl>distance) && (next_tp==0 || next_tp-quote>distance);
   return (next_sl==0 || next_sl-quote>distance) && (next_tp==0 || quote-next_tp>distance);
  }

//+------------------------------------------------------------------+
//| Detect any open position on the current symbol                    |
//+------------------------------------------------------------------+
bool HasSymbolPosition()
  {
   //--- Netting positions may combine deals with different magic numbers
   for(int i=PositionsTotal()-1;i>=0;i--)
      if(PositionGetTicket(i)>0 && PositionGetString(POSITION_SYMBOL)==_Symbol)
         return true;
   return false;
  }

//+------------------------------------------------------------------+
//| Cancel owned pending entries while a symbol position is open      |
//+------------------------------------------------------------------+
void CancelPendingAfterFill()
  {
   if(!HasSymbolPosition() || !TradingSessionOpen()) return;
   //--- Retry on later ticks if the order is currently frozen
   static datetime last_attempt=0;
   if(TimeCurrent()-last_attempt<1) return;
   for(int i=OrdersTotal()-1;i>=0;i--)
     {
      ulong ticket=OrderGetTicket(i);
      if(!OurOrder(ticket)) continue;
      ENUM_ORDER_TYPE type=(ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      if(type!=ORDER_TYPE_BUY_STOP && type!=ORDER_TYPE_SELL_STOP) continue;
      MqlTick tick;
      if(!SymbolInfoTick(_Symbol,tick)) continue;
      double quote=type==ORDER_TYPE_BUY_STOP?tick.ask:tick.bid;
      double freeze=SymbolInfoInteger(_Symbol,SYMBOL_TRADE_FREEZE_LEVEL)*g_point;
      if(freeze>0 && MathAbs(OrderGetDouble(ORDER_PRICE_OPEN)-quote)<=freeze+MathMax(g_tick_size,g_point))
         continue;
      last_attempt=TimeCurrent();
      bool ok=trade.OrderDelete(ticket);
      PrintFormat("Cancel pending after fill: order=%I64u call_ok=%s retcode=%u description=%s",
                  ticket,ok?"true":"false",trade.ResultRetcode(),trade.ResultRetcodeDescription());
     }
  }

//+------------------------------------------------------------------+
//| Place a pending breakout order for one direction                 |
//+------------------------------------------------------------------+
void PlaceBreakout(bool buy)
  {
   //--- Never add pending entries while this symbol has a position
   if(HasSymbolPosition()) return;
   //--- Skip submissions outside the broker trading sessions
   if(!TradingSessionOpen()) return;
//--- Enforce the pending order limit for this direction
   ENUM_ORDER_TYPE type=buy?ORDER_TYPE_BUY_STOP:ORDER_TYPE_SELL_STOP;
   if(CountPending(type)>=InpMaxPending)
      return;
//--- Find a confirmed swing and check market clearance
   double swing=FindSwing(buy);
   if(swing<=0)
      return;
   double bid=SymbolInfoDouble(_Symbol,SYMBOL_BID), ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK);
   double market=buy?ask:bid;
   if(buy && market>=swing-Pct(swing,InpMinFractalClearancePct))
      return;
   if(!buy && market<=swing+Pct(swing,InpMinFractalClearancePct))
      return;
//--- Apply the entry offset and reject duplicate orders
   double entry=buy?swing+Pct(swing,InpBuyEntryOffsetPct):swing-Pct(swing,InpSellEntryOffsetPct);
   entry=N(entry);
   if(SimilarPending(type,entry))
      return;
//--- Calculate initial stop loss and take profit
   double sl=buy?entry-Pct(entry,InpStopLossPct):entry+Pct(entry,InpStopLossPct);
   double tp=buy?entry+Pct(entry,InpTakeProfitPct):entry-Pct(entry,InpTakeProfitPct);
   sl=N(sl);
   tp=N(tp);
//--- Check the broker minimum pending entry distance
   double stop_level=SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL)*g_point;
   if(buy && entry<=ask+stop_level)
      return;
   if(!buy && entry>=bid-stop_level)
      return;
//--- Calculate volume and prepare the expiry input
   double lots=AffordableVolume(buy,entry,LimitDirectionalVolume(buy,LotsForRisk(entry,sl)));
   if(lots<=0)
      return;
   datetime expiry=InpPendingExpiryHours>0 ? TimeCurrent()+InpPendingExpiryHours*3600 : 0;
   trade.SetExpertMagicNumber(InpMagic);
   //--- Log every pending-order argument before submission
   PrintFormat("Pending order request: symbol=%s type=%s lots=%.8f entry=%s sl=%s tp=%s time_type=%s expiry=%s magic=%I64u comment=%s",
               _Symbol,EnumToString(type),lots,
               DoubleToString(entry,g_digits),DoubleToString(sl,g_digits),
               DoubleToString(tp,g_digits),EnumToString(ORDER_TIME_GTC),
               expiry>0 ? TimeToString(expiry,TIME_DATE|TIME_SECONDS) : "0",
               InpMagic,InpComment);
   //--- Log the current quote and broker constraints for diagnosis
   PrintFormat("Pending order context: bid=%s ask=%s swing=%s point=%.10f tick_size=%.10f stops_level=%I64d stop_distance=%s volume_min=%.8f volume_max=%.8f volume_step=%.8f volume_limit=%.8f lot_mode=%s fixed_lots=%.8f risk_percent=%.8f signal_tf=H1",
               DoubleToString(bid,g_digits),DoubleToString(ask,g_digits),
               DoubleToString(swing,g_digits),g_point,g_tick_size,
               SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL),
               DoubleToString(stop_level,g_digits),
               SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN),
               SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX),
               SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP),
               SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_LIMIT),
               EnumToString(InpLotMode),InpFixedLots,InpRiskPercent);
   //--- Validate the complete request before submitting it
   if(!CheckPendingRequest(type,lots,entry,sl,tp,expiry)) return;
//--- Submit a GTC pending order and report failure
   bool ok=buy ? trade.BuyStop(lots,entry,_Symbol,sl,tp,ORDER_TIME_GTC,expiry,InpComment)
           : trade.SellStop(lots,entry,_Symbol,sl,tp,ORDER_TIME_GTC,expiry,InpComment);
   uint retcode=trade.ResultRetcode();
   //--- Log the server result for successful and failed submissions
   PrintFormat("Pending order result: call_ok=%s retcode=%u description=%s order=%I64u deal=%I64u volume=%.8f price=%s broker_comment=%s",
               ok ? "true" : "false",retcode,trade.ResultRetcodeDescription(),
               trade.ResultOrder(),trade.ResultDeal(),trade.ResultVolume(),
               DoubleToString(trade.ResultPrice(),g_digits),trade.ResultComment());
   if(!ok || (retcode!=TRADE_RETCODE_DONE && retcode!=TRADE_RETCODE_PLACED))
      PrintFormat("Pending order failed: %s; lots=%.8f min=%.8f max=%.8f step=%.8f limit=%.8f",
                  trade.ResultRetcodeDescription(),lots,
                  SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN),
                  SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX),
                  SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP),
                  SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_LIMIT));
  }

//+------------------------------------------------------------------+
//| Update break-even, trailing stops and salvage targets            |
//+------------------------------------------------------------------+
void ManagePositions()
  {
   if(!TradingSessionOpen()) return;
   //--- Bound repeated requests when a server rejects modifications
   static datetime last_attempt=0;
   if(TimeCurrent()-last_attempt<5) return;
//--- Inspect open positions
   for(int i=PositionsTotal()-1;i>=0;i--)
     {
      ulong ticket=PositionGetTicket(i);
      if(!OurPosition(ticket))
         continue;
      //--- Calculate favorable and adverse price movement
      long type=PositionGetInteger(POSITION_TYPE);
      double open=PositionGetDouble(POSITION_PRICE_OPEN), sl=PositionGetDouble(POSITION_SL), tp=PositionGetDouble(POSITION_TP);
      double price=(type==POSITION_TYPE_BUY)?SymbolInfoDouble(_Symbol,SYMBOL_BID):SymbolInfoDouble(_Symbol,SYMBOL_ASK);
      double move=type==POSITION_TYPE_BUY ? price-open : open-price;
      double favorable_pct=move/open*100.0;
      double loss_pct=(-move)/open*100.0;
      double new_sl=sl, new_tp=tp;
      //--- Lock profit after the break-even trigger
      if(favorable_pct>=InpBreakEvenTriggerPct)
         new_sl=type==POSITION_TYPE_BUY?MathMax(new_sl,open+Pct(open,InpBreakEvenLockPct)):MathMin(new_sl,open-Pct(open,InpBreakEvenLockPct));
      //--- Trail the stop within the configured gain range
      if(favorable_pct>=InpTrailTriggerPct && favorable_pct<=InpMaxTrailPct)
         new_sl=type==POSITION_TYPE_BUY?MathMax(new_sl,price-Pct(price,InpTrailDistancePct)):MathMin(new_sl,price+Pct(price,InpTrailDistancePct));
      //--- Set a salvage exit target after the loss trigger
      if(loss_pct>=InpSalvageTriggerPct)
         new_tp=type==POSITION_TYPE_BUY?open-Pct(open,InpSalvageExitPct):open+Pct(open,InpSalvageExitPct);
      //--- Normalize prices and modify only when values change
      new_sl=N(new_sl);
      new_tp=N(new_tp);
      if((new_sl!=sl || new_tp!=tp) && CanModifyPosition(type,sl,tp,new_sl,new_tp,price))
        {
         last_attempt=TimeCurrent();
         bool ok=trade.PositionModify(ticket,new_sl,new_tp);
         uint result=trade.ResultRetcode();
         if(!ok || (result!=TRADE_RETCODE_DONE && result!=TRADE_RETCODE_NO_CHANGES))
            PrintFormat("Position modify rejected: ticket=%I64u retcode=%u description=%s",
                        ticket,result,trade.ResultRetcodeDescription());
        }
     }
  }

//+------------------------------------------------------------------+
//| Initialize symbol properties and validate input parameters       |
//+------------------------------------------------------------------+
int OnInit()
  {
//--- Cache symbol pricing properties
   g_point=SymbolInfoDouble(_Symbol,SYMBOL_POINT);
   g_digits=(int)SymbolInfoInteger(_Symbol,SYMBOL_DIGITS);
   g_tick_size=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);
   g_tick_value=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_VALUE);
//--- Validate required positive counts
   if(InpFractalLeft<1 || InpFractalRight<1 || InpMaxPending<1 || InpMaxPositions<1 ||
      InpFixedLots<=0 || !MathIsValidNumber(InpFixedLots) ||
      (InpLotMode==LOT_RISK_PERCENT && (InpRiskPercent<=0 || !MathIsValidNumber(InpRiskPercent))))
      return INIT_PARAMETERS_INCORRECT;
   PrintFormat("Symbol volume specifications: min=%.8f max=%.8f step=%.8f limit=%.8f; signal timeframe=H1",
               SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN),
               SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX),
               SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP),
               SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_LIMIT));
   trade.SetExpertMagicNumber(InpMagic);
   return INIT_SUCCEEDED;
  }

//+------------------------------------------------------------------+
//| Manage positions and periodically scan for breakout entries      |
//+------------------------------------------------------------------+
void OnTick()
  {
//--- Manage positions before checking the entry limit
   CancelPendingAfterFill();
   if(TradingSessionOpen()) ReviewPendingMargin();
   ManagePositions();
   //--- Existing positions block both buy and sell entry scans
   if(HasSymbolPosition()) return;
   if(CountPositions()>=InpMaxPositions)
      return;
//--- Throttle scans using the configured interval
   datetime now=TimeCurrent();
   if(g_last_scan!=0 && now-g_last_scan<InpRescanMinutes*60)
      return;
   g_last_scan=now;
//--- Scan buy and sell breakout directions
   PlaceBreakout(true);
   PlaceBreakout(false);
  }
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//| Cancel remaining pending entries immediately after a deal         |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
  {
   //--- Also retry on ticks if the server temporarily blocks deletion
   if(trans.type==TRADE_TRANSACTION_DEAL_ADD && trans.symbol==_Symbol)
      CancelPendingAfterFill();
  }
