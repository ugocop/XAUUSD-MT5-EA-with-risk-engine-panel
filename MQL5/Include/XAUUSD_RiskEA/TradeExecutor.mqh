//+------------------------------------------------------------------+
//|                                                TradeExecutor.mqh |
//|  XAUUSD Risk EA - market entries, close-all, break-even, ATR     |
//|  trail. One position per direction, risk-sized lots only: no     |
//|  add-ons, no pending ladders, no recovery sizing.                |
//+------------------------------------------------------------------+
#include <Trade/Trade.mqh>
#include "Utils.mqh"
#include "Signal.mqh"
#include "RiskManager.mqh"

class CTradeExecutor
  {
private:
   CTrade            m_trade;
   CRiskManager     *m_risk;
   ulong             m_magic;
   string            m_comment;
   int               m_slippage;
   double            m_sl_atr_mult;
   double            m_rr;
   double            m_be_r;
   int               m_be_buffer_pts;
   double            m_trail_start_r;
   double            m_trail_atr_mult;
   string            m_isl_prefix;
   datetime          m_close_retry_at;
   datetime          m_modify_retry_at;

   bool              SelectOurPosition(const ulong ticket) const
     {
      if(!PositionSelectByTicket(ticket))
         return false;
      return (PositionGetString(POSITION_SYMBOL) == _Symbol &&
              (ulong)PositionGetInteger(POSITION_MAGIC) == m_magic);
     }

   bool              IsRetryable(const uint rc) const
     {
      return (rc == TRADE_RETCODE_REQUOTE || rc == TRADE_RETCODE_PRICE_CHANGED || rc == TRADE_RETCODE_TIMEOUT);
     }

   bool              IsDone(const uint rc) const
     {
      return (rc == TRADE_RETCODE_DONE || rc == TRADE_RETCODE_DONE_PARTIAL || rc == TRADE_RETCODE_PLACED);
     }

   void              LogFailure(const string what, const double price, const double sl, const double tp)
     {
      LogError(StringFormat("%s failed: retcode=%u (%s) deal=%I64u price=%s sl=%s tp=%s",
                            what, m_trade.ResultRetcode(), m_trade.ResultRetcodeDescription(),
                            m_trade.ResultDeal(), FmtPrice(price), FmtPrice(sl), FmtPrice(tp)));
     }

   //--- initial SL per position id, so R does not change after BE moves the stop
   void              StoreInitialSL(const ulong position_id, const double sl)
     {
      GlobalVariableSet(m_isl_prefix + IntegerToString((long)position_id), sl);
     }

   double            InitialSL(const ulong position_id, const double current_sl)
     {
      string name = m_isl_prefix + IntegerToString((long)position_id);
      if(GlobalVariableCheck(name))
         return GlobalVariableGet(name);
      if(HistoryOrderSelect(position_id))
        {
         double sl = HistoryOrderGetDouble(position_id, ORDER_SL);
         if(sl > 0.0)
           {
            GlobalVariableSet(name, sl);
            return sl;
           }
        }
      return current_sl;
     }

   bool              SendMarket(const ENUM_ORDER_TYPE type, const double lots, const double sl_dist, const double tp_dist)
     {
      for(int attempt = 0; attempt < 2; attempt++)
        {
         MqlTick tick;
         if(!SymbolInfoTick(_Symbol, tick))
           {
            LogError("SymbolInfoTick failed before order send");
            return false;
           }
         bool   buy   = (type == ORDER_TYPE_BUY);
         double entry = buy ? tick.ask : tick.bid;
         double sl    = buy ? NormalizePrice(entry - sl_dist, -1) : NormalizePrice(entry + sl_dist, 1);
         double tp    = buy ? NormalizePrice(entry + tp_dist, 1)  : NormalizePrice(entry - tp_dist, -1);

         bool ok = buy ? m_trade.Buy(lots, _Symbol, entry, sl, tp, m_comment)
                       : m_trade.Sell(lots, _Symbol, entry, sl, tp, m_comment);
         uint rc = m_trade.ResultRetcode();
         if(ok && IsDone(rc))
           {
            ulong position_id = m_trade.ResultOrder();
            StoreInitialSL(position_id, sl);
            LogInfo(StringFormat("%s opened: retcode=%u ticket=%I64u deal=%I64u lots=%.2f price=%s sl=%s tp=%s",
                                 buy ? "BUY" : "SELL", rc, position_id, m_trade.ResultDeal(), lots,
                                 FmtPrice(m_trade.ResultPrice() > 0.0 ? m_trade.ResultPrice() : entry), FmtPrice(sl), FmtPrice(tp)));
            return true;
           }
         LogFailure(buy ? "BUY" : "SELL", entry, sl, tp);
         if(attempt == 0 && IsRetryable(rc))
           {
            LogInfo("Retrying once with a fresh quote");
            continue;
           }
         return false;
        }
      return false;
     }

   void              Manage(const double atr1, const double close1, const bool do_be, const bool do_trail)
     {
      if(TimeCurrent() < m_modify_retry_at || !IsTradeSessionOpen())
         return;
      MqlTick tick;
      if(!SymbolInfoTick(_Symbol, tick))
         return;

      double tick_size = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
      if(tick_size <= 0.0)
         tick_size = _Point;
      double min_gap   = MinStopDistance();
      double freeze    = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL) * _Point;
      double be_buffer = PointsToPrice(m_be_buffer_pts);

      for(int i = PositionsTotal() - 1; i >= 0; i--)
        {
         ulong ticket = PositionGetTicket(i);
         if(ticket == 0 || !SelectOurPosition(ticket))
            continue;

         bool   buy   = ((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY);
         double open  = PositionGetDouble(POSITION_PRICE_OPEN);
         double sl    = PositionGetDouble(POSITION_SL);
         double tp    = PositionGetDouble(POSITION_TP);
         ulong  pid   = (ulong)PositionGetInteger(POSITION_IDENTIFIER);
         double isl   = InitialSL(pid, sl);
         double r     = MathAbs(open - isl);
         if(isl <= 0.0 || r <= 0.0)
            continue;

         double price = buy ? tick.bid : tick.ask;
         double move  = buy ? price - open : open - price;

         double cand = 0.0;
         string why  = "";
         if(do_be && move >= m_be_r * r)
           {
            cand = buy ? open + be_buffer : open - be_buffer;
            why  = "break-even";
           }
         if(do_trail && atr1 > 0.0 && move >= m_trail_start_r * r)
           {
            double trail = buy ? close1 - atr1 * m_trail_atr_mult : close1 + atr1 * m_trail_atr_mult;
            if(why == "" || (buy ? trail > cand : trail < cand))
              {
               cand = trail;
               why  = "ATR trail";
              }
           }
         if(why == "")
            continue;

         cand = NormalizePrice(cand, buy ? -1 : 1);

         //--- never loosen: strictly better than the current SL
         if(sl > 0.0 && (buy ? cand <= sl + tick_size * 0.5 : cand >= sl - tick_size * 0.5))
            continue;
         //--- must stay outside the stops/freeze gap from the current price
         if(buy ? (price - cand) < min_gap : (cand - price) < min_gap)
           {
            LogDebug(StringFormat("%s SL %s for #%I64u inside broker stop gap; waiting", why, FmtPrice(cand), ticket));
            continue;
           }
         if(freeze > 0.0 && ((sl > 0.0 && MathAbs(price - sl) <= freeze) || (tp > 0.0 && MathAbs(tp - price) <= freeze)))
            continue;

         if(m_trade.PositionModify(ticket, cand, tp))
           {
            LogInfo(StringFormat("%s: #%I64u SL %s -> %s (R=%s, move=%.2fR)", why, ticket, FmtPrice(sl), FmtPrice(cand),
                                 FmtPrice(r), move / r));
           }
         else
           {
            LogFailure(StringFormat("SL modify (%s) #%I64u", why, ticket), price, cand, tp);
            m_modify_retry_at = TimeCurrent() + 10;
           }
        }
     }

public:
                     CTradeExecutor(void) : m_risk(NULL), m_magic(0), m_comment(""), m_slippage(30),
                     m_sl_atr_mult(1.5), m_rr(2.0), m_be_r(1.0), m_be_buffer_pts(20),
                     m_trail_start_r(1.0), m_trail_atr_mult(1.0), m_isl_prefix(""),
                     m_close_retry_at(0), m_modify_retry_at(0) {}

   void              Init(CRiskManager *risk, const ulong magic, const string comment, const int slippage,
                          const double sl_atr_mult, const double rr,
                          const double be_r, const int be_buffer_pts,
                          const double trail_start_r, const double trail_atr_mult)
     {
      m_risk           = risk;
      m_magic          = magic;
      m_comment        = comment;
      m_slippage       = slippage;
      m_sl_atr_mult    = sl_atr_mult;
      m_rr             = rr;
      m_be_r           = be_r;
      m_be_buffer_pts  = be_buffer_pts;
      m_trail_start_r  = trail_start_r;
      m_trail_atr_mult = trail_atr_mult;
      m_isl_prefix     = XRE_PREFIX + IntegerToString((long)magic) + "_ISL_";

      m_trade.SetExpertMagicNumber(magic);
      m_trade.SetDeviationInPoints((ulong)slippage);
      m_trade.SetTypeFillingBySymbol(_Symbol);
      m_trade.LogLevel(LOG_LEVEL_ERRORS);
     }

   int               CountPositions(const ENUM_POSITION_TYPE type) const
     {
      int n = 0;
      for(int i = PositionsTotal() - 1; i >= 0; i--)
        {
         ulong ticket = PositionGetTicket(i);
         if(ticket == 0 || !SelectOurPosition(ticket))
            continue;
         if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) == type)
            n++;
        }
      return n;
     }

   int               CountAll(void) const
     {
      return CountPositions(POSITION_TYPE_BUY) + CountPositions(POSITION_TYPE_SELL);
     }

   //--- "BUY 0.10", "BUY 0.10 + SELL 0.05" or "FLAT"; floating = profit + swap
   string            PositionSummary(double &floating) const
     {
      double buy_vol = 0.0, sell_vol = 0.0;
      floating = 0.0;
      for(int i = PositionsTotal() - 1; i >= 0; i--)
        {
         ulong ticket = PositionGetTicket(i);
         if(ticket == 0 || !SelectOurPosition(ticket))
            continue;
         if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY)
            buy_vol += PositionGetDouble(POSITION_VOLUME);
         else
            sell_vol += PositionGetDouble(POSITION_VOLUME);
         floating += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
        }
      string txt = "";
      if(buy_vol > 0.0)
         txt = "BUY " + DoubleToString(buy_vol, 2);
      if(sell_vol > 0.0)
         txt += (txt == "" ? "" : " + ") + "SELL " + DoubleToString(sell_vol, 2);
      if(txt == "")
         txt = "FLAT";
      return txt;
     }

   //--- market entry for a confirmed closed-bar signal
   bool              Open(const ENUM_SIGNAL signal, const double atr, const string signal_info)
     {
      if(signal == SIGNAL_NONE || m_risk == NULL)
         return false;
      bool               buy   = (signal == SIGNAL_BUY);
      string             side  = buy ? "BUY" : "SELL";
      ENUM_ORDER_TYPE    otype = buy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
      ENUM_POSITION_TYPE ptype = buy ? POSITION_TYPE_BUY : POSITION_TYPE_SELL;

      if(CountPositions(ptype) > 0)
        {
         LogInfo(side + " signal skipped: a " + side + " position is already open (one per direction, no add-ons)");
         return false;
        }
      if(atr <= 0.0)
        {
         LogInfo(side + " signal skipped: ATR not positive");
         return false;
        }

      MqlTick tick;
      if(!SymbolInfoTick(_Symbol, tick))
        {
         LogError("SymbolInfoTick failed");
         return false;
        }
      double entry = buy ? tick.ask : tick.bid;

      double atr_sl_dist = atr * m_sl_atr_mult;
      double sl_dist     = atr_sl_dist;
      double min_dist    = MinStopDistance();
      if(sl_dist < min_dist)
        {
         sl_dist = min_dist;
         LogInfo(StringFormat("SL widened to broker minimum (%s -> %s); lots recalculated for the wider stop",
                              FmtPrice(atr_sl_dist), FmtPrice(sl_dist)));
        }
      sl_dist = CeilToTick(sl_dist);
      double tp_dist = CeilToTick(sl_dist * m_rr);
      if(tp_dist < min_dist)
        {
         LogInfo(StringFormat("%s signal skipped: TP distance %s below broker minimum %s", side, FmtPrice(tp_dist), FmtPrice(min_dist)));
         return false;
        }

      double lots = m_risk.CalcLots(sl_dist, otype, entry, true);
      if(lots <= 0.0)
        {
         LogInfo(side + " signal skipped: lots too small");
         return false;
        }

      //--- guard: only the fresh risk-% size may be sent
      double fresh = m_risk.CalcLots(sl_dist, otype, entry, false);
      double step  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
      if(fresh <= 0.0 || MathAbs(lots - fresh) > step + 1e-9 || CountPositions(ptype) > 0)
        {
         LogError(StringFormat("Order refused by no-martingale guard: lots=%.2f fresh=%.2f open_same_side=%d",
                               lots, fresh, CountPositions(ptype)));
         return false;
        }

      LogInfo(StringFormat("%s signal: %s; entry~%s SL_dist=%s TP_dist=%s", side, signal_info,
                           FmtPrice(entry), FmtPrice(sl_dist), FmtPrice(tp_dist)));
      LogInfo(StringFormat("lots=%.2f risk%%=%.2f", lots, m_risk.RiskPercent()));

      return SendMarket(otype, lots, sl_dist, tp_dist);
     }

   bool              CloseByTicket(const ulong ticket, const string reason)
     {
      for(int attempt = 0; attempt < 2; attempt++)
        {
         if(!SelectOurPosition(ticket))
            return true;
         double vol = PositionGetDouble(POSITION_VOLUME);
         if(m_trade.PositionClose(ticket, (ulong)m_slippage) && IsDone(m_trade.ResultRetcode()))
           {
            LogInfo(StringFormat("Closed #%I64u (%.2f lots) - %s, retcode=%u", ticket, vol, reason, m_trade.ResultRetcode()));
            return true;
           }
         LogFailure(StringFormat("Close #%I64u", ticket), m_trade.ResultPrice(), 0.0, 0.0);
         if(attempt == 0 && IsRetryable(m_trade.ResultRetcode()))
            continue;
         return false;
        }
      return false;
     }

   //--- close every position and delete every pending order of this EA on this symbol
   bool              CloseAll(const string reason)
     {
      if(TimeCurrent() < m_close_retry_at)
         return false;
      if(!IsTradeSessionOpen())
        {
         LogInfo("Close all (" + reason + ") deferred: market closed, retry when the trade session opens");
         m_close_retry_at = TimeCurrent() + 60;
         return false;
        }
      bool all_ok = true;
      int  closed = 0;
      for(int i = PositionsTotal() - 1; i >= 0; i--)
        {
         ulong ticket = PositionGetTicket(i);
         if(ticket == 0 || !SelectOurPosition(ticket))
            continue;
         if(CloseByTicket(ticket, reason))
            closed++;
         else
            all_ok = false;
        }
      for(int i = OrdersTotal() - 1; i >= 0; i--)
        {
         ulong ticket = OrderGetTicket(i);
         if(ticket == 0)
            continue;
         if(OrderGetString(ORDER_SYMBOL) != _Symbol || (ulong)OrderGetInteger(ORDER_MAGIC) != m_magic)
            continue;
         if(m_trade.OrderDelete(ticket))
            LogInfo(StringFormat("Deleted pending #%I64u - %s", ticket, reason));
         else
           {
            LogFailure(StringFormat("Delete pending #%I64u", ticket), 0.0, 0.0, 0.0);
            all_ok = false;
           }
        }
      if(closed > 0 || !all_ok)
         LogInfo(StringFormat("Close all (%s): %d closed, %s", reason, closed, all_ok ? "complete" : "INCOMPLETE - retry in 10s"));
      if(!all_ok)
         m_close_retry_at = TimeCurrent() + 10;
      return all_ok;
     }

   void              ManageBreakEven(void)                              { Manage(0.0, 0.0, true, false); }
   void              ManageTrail(const double atr1, const double close1) { Manage(atr1, close1, false, true); }
   void              ManagePositions(const double atr1, const double close1) { Manage(atr1, close1, true, true); }

   //--- drop stored initial SLs of positions that no longer exist
   void              CleanupInitialSL(void)
     {
      for(int i = GlobalVariablesTotal() - 1; i >= 0; i--)
        {
         string name = GlobalVariableName(i);
         if(StringFind(name, m_isl_prefix) != 0)
            continue;
         ulong pid = (ulong)StringToInteger(StringSubstr(name, StringLen(m_isl_prefix)));
         bool  alive = false;
         for(int p = PositionsTotal() - 1; p >= 0 && !alive; p--)
           {
            ulong ticket = PositionGetTicket(p);
            if(ticket != 0 && (ulong)PositionGetInteger(POSITION_IDENTIFIER) == pid)
               alive = true;
           }
         if(!alive)
            GlobalVariableDel(name);
        }
     }
  };
//+------------------------------------------------------------------+
