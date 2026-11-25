//+------------------------------------------------------------------+
//|                                                  RiskManager.mqh |
//|  XAUUSD Risk EA - risk sizing, daily loss, max DD, trade count,  |
//|  spread / session gates, persisted locks.                        |
//|  Lot size never grows after a loss or a win: every entry is a    |
//|  fresh risk-% calculation.                                       |
//+------------------------------------------------------------------+
#include "Utils.mqh"
#include "Session.mqh"

enum ENUM_DAILY_LOSS_MODE
  {
   DAILY_LOSS_PERCENT = 0,
   DAILY_LOSS_MONEY   = 1
  };

class CRiskManager
  {
private:
   //--- settings
   ulong             m_magic;
   double            m_risk_pct;
   double            m_max_lot;
   ENUM_DAILY_LOSS_MODE m_dl_mode;
   double            m_dl_pct;
   double            m_dl_money;
   double            m_max_dd_pct;
   int               m_max_trades;
   int               m_max_spread;
   CSession         *m_session;
   string            m_gv;

   //--- persisted state
   double            m_sod_equity;
   int               m_sod_date;
   double            m_hwm;
   bool              m_daily_block;
   bool              m_dd_block;
   bool              m_paused;

   //--- computed state
   double            m_closed_pnl;
   double            m_floating;
   double            m_daily_pnl;
   double            m_dd_pct;
   int               m_trades_today;
   int               m_open_count;
   bool              m_history_dirty;
   bool              m_state_changed;
   string            m_note;

   double            GVGet(const string key, const double def) const
     {
      string name = m_gv + key;
      if(!GlobalVariableCheck(name))
         return def;
      return GlobalVariableGet(name);
     }
   void              GVSet(const string key, const double value) const { GlobalVariableSet(m_gv + key, value); }
   void              GVDel(const string key) const { GlobalVariableDel(m_gv + key); }

   void              PersistDay(void) const
     {
      GVSet("SOD_EQ", m_sod_equity);
      GVSet("SOD_DATE", (double)m_sod_date);
      GVSet("DAILY_BLOCK", m_daily_block ? 1.0 : 0.0);
      GlobalVariablesFlush();
     }

   bool              IsOurDeal(const ulong ticket) const
     {
      return (HistoryDealGetString(ticket, DEAL_SYMBOL) == _Symbol &&
              (ulong)HistoryDealGetInteger(ticket, DEAL_MAGIC) == m_magic);
     }

   //--- closed P/L and entry count from today's deals (server date)
   void              RecalcHistory(void)
     {
      if(!HistorySelect(ServerMidnight(), TimeCurrent() + 3600))
        {
         LogError("HistorySelect failed; daily P/L kept from previous calculation");
         return;
        }
      double pnl    = 0.0;
      int    trades = 0;
      int    total  = HistoryDealsTotal();
      for(int i = 0; i < total; i++)
        {
         ulong ticket = HistoryDealGetTicket(i);
         if(ticket == 0 || !IsOurDeal(ticket))
            continue;
         pnl += HistoryDealGetDouble(ticket, DEAL_PROFIT)
                + HistoryDealGetDouble(ticket, DEAL_SWAP)
                + HistoryDealGetDouble(ticket, DEAL_COMMISSION)
                + HistoryDealGetDouble(ticket, DEAL_FEE);
         ENUM_DEAL_ENTRY entry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(ticket, DEAL_ENTRY);
         if(entry == DEAL_ENTRY_IN || entry == DEAL_ENTRY_INOUT)
            trades++;
        }
      m_closed_pnl    = pnl;
      m_trades_today  = trades;
      m_history_dirty = false;
     }

   void              RecalcFloating(void)
     {
      double fl = 0.0;
      int    n  = 0;
      for(int i = PositionsTotal() - 1; i >= 0; i--)
        {
         ulong ticket = PositionGetTicket(i);
         if(ticket == 0)
            continue;
         if(PositionGetString(POSITION_SYMBOL) != _Symbol || (ulong)PositionGetInteger(POSITION_MAGIC) != m_magic)
            continue;
         fl += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
         n++;
        }
      m_floating   = fl;
      m_open_count = n;
     }

   void              ClearLocks(const string why)
     {
      LogInfo("Risk locks cleared (" + why + "): daily-loss lock, max-DD lock, equity high-water mark");
      GVDel("DAILY_BLOCK");
      GVDel("DD_BLOCK");
      GVDel("HWM");
      GlobalVariablesFlush();
     }

public:
                     CRiskManager(void) : m_magic(0), m_risk_pct(0.5), m_max_lot(0.0), m_dl_mode(DAILY_LOSS_PERCENT),
                     m_dl_pct(2.0), m_dl_money(0.0), m_max_dd_pct(6.0), m_max_trades(4), m_max_spread(50),
                     m_session(NULL), m_gv(""), m_sod_equity(0.0), m_sod_date(0), m_hwm(0.0),
                     m_daily_block(false), m_dd_block(false), m_paused(false),
                     m_closed_pnl(0.0), m_floating(0.0), m_daily_pnl(0.0), m_dd_pct(0.0),
                     m_trades_today(0), m_open_count(0), m_history_dirty(true), m_state_changed(true), m_note("") {}

   bool              Init(const ulong magic, const double risk_pct, const double max_lot,
                          const ENUM_DAILY_LOSS_MODE dl_mode, const double dl_pct, const double dl_money,
                          const double max_dd_pct, const int max_trades, const int max_spread,
                          CSession *session, const bool clear_locks)
     {
      m_magic      = magic;
      m_risk_pct   = risk_pct;
      m_max_lot    = max_lot;
      m_dl_mode    = dl_mode;
      m_dl_pct     = dl_pct;
      m_dl_money   = dl_money;
      m_max_dd_pct = max_dd_pct;
      m_max_trades = max_trades;
      m_max_spread = max_spread;
      m_session    = session;
      m_gv         = XRE_PREFIX + IntegerToString((long)magic) + "_";

      if(clear_locks)
         ClearLocks("InpClearRiskLocks=true on init");

      double eq = AccountInfoDouble(ACCOUNT_EQUITY);

      m_hwm = GVGet("HWM", 0.0);
      if(m_hwm <= 0.0)
        {
         m_hwm = eq;
         GVSet("HWM", m_hwm);
        }
      m_dd_block = (GVGet("DD_BLOCK", 0.0) > 0.5);

      int today  = DateKey(TimeCurrent());
      int stored = (int)GVGet("SOD_DATE", 0.0);
      if(stored == today && GlobalVariableCheck(m_gv + "SOD_EQ"))
        {
         m_sod_date    = today;
         m_sod_equity  = GVGet("SOD_EQ", eq);
         m_daily_block = (GVGet("DAILY_BLOCK", 0.0) > 0.5);
         LogInfo(StringFormat("Restored today's start-of-day equity %.2f (daily-loss lock %s)", m_sod_equity, m_daily_block ? "ON" : "off"));
        }
      else
        {
         m_sod_date    = today;
         m_sod_equity  = eq;
         m_daily_block = false;
         PersistDay();
         LogInfo(StringFormat("No start-of-day record for today: SOD equity = current equity %.2f", m_sod_equity));
        }

      m_paused = (GVGet("PAUSED", 0.0) > 0.5);
      if(m_paused)
         LogInfo("User pause restored from previous session");
      if(m_dd_block)
         LogInfo("Max-DD lock is active from a previous session (clears only with InpClearRiskLocks=true on init)");

      m_history_dirty = true;
      m_state_changed = true;
      return true;
     }

   void              Deinit(const int reason, const bool clear_locks)
     {
      if(reason == REASON_REMOVE && clear_locks)
        {
         GlobalVariablesDeleteAll(m_gv);
         LogInfo("EA removed with InpClearRiskLocks=true: all persisted risk state deleted");
        }
     }

   //--- called on every tick before anything else
   void              Update(void)
     {
      double eq    = AccountInfoDouble(ACCOUNT_EQUITY);
      int    today = DateKey(TimeCurrent());

      if(today != m_sod_date)
        {
         if(m_daily_block)
            LogInfo("Daily-loss lock cleared: new server date");
         m_sod_date      = today;
         m_sod_equity    = eq;
         m_daily_block   = false;
         m_history_dirty = true;
         m_state_changed = true;
         PersistDay();
         LogInfo(StringFormat("New server day %d: SOD equity %.2f", today, m_sod_equity));
        }

      if(eq > m_hwm)
        {
         m_hwm = eq;
         GVSet("HWM", m_hwm);
        }

      if(m_history_dirty)
         RecalcHistory();
      RecalcFloating();

      m_daily_pnl = m_closed_pnl + m_floating;
      m_dd_pct    = (m_hwm > 0.0) ? (m_hwm - eq) / m_hwm * 100.0 : 0.0;

      if(!m_dd_block && m_dd_pct >= m_max_dd_pct)
        {
         m_dd_block      = true;
         m_state_changed = true;
         GVSet("DD_BLOCK", 1.0);
         GlobalVariablesFlush();
         LogInfo(StringFormat("MAX DD LOCK: DD %.2f%% >= %.2f%% (HWM %.2f, equity %.2f). Closing all, no new trades.",
                              m_dd_pct, m_max_dd_pct, m_hwm, eq));
        }

      double limit = DailyLimit();
      if(!m_daily_block && limit > 0.0 && m_daily_pnl <= -limit)
        {
         m_daily_block   = true;
         m_state_changed = true;
         GVSet("DAILY_BLOCK", 1.0);
         GlobalVariablesFlush();
         LogInfo(StringFormat("DAILY LOSS LOCK: daily P/L %.2f <= -%.2f (SOD equity %.2f). Closing all, blocked until next server date.",
                              m_daily_pnl, limit, m_sod_equity));
        }
     }

   //--- risk-% position size, floored to the volume step; 0 = reject
   double            CalcLots(const double sl_distance, const ENUM_ORDER_TYPE type, const double price, const bool verbose = true)
     {
      if(sl_distance <= 0.0)
        {
         LogError("CalcLots: SL distance must be > 0");
         return 0.0;
        }
      double tick_size  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
      double tick_value = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
      if(tick_size <= 0.0 || tick_value <= 0.0)
        {
         LogError(StringFormat("CalcLots: invalid tick size %.5f / tick value %.5f", tick_size, tick_value));
         return 0.0;
        }

      double equity     = AccountInfoDouble(ACCOUNT_EQUITY);
      double money_risk = equity * m_risk_pct / 100.0;
      double raw        = money_risk / (sl_distance / tick_size * tick_value);

      double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
      double vmin = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
      double vmax = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
      if(m_max_lot > 0.0)
         vmax = MathMin(vmax, m_max_lot);

      double lots = NormalizeVolume(raw);
      if(verbose)
         LogInfo(StringFormat("Sizing: equity=%.2f risk%%=%.2f money_risk=%.2f sl_dist=%s tick_size=%s tick_value=%.5f raw_lots=%.4f floored=%.2f",
                              equity, m_risk_pct, money_risk, FmtPrice(sl_distance), FmtPrice(tick_size), tick_value, raw, lots));

      if(lots < vmin - 1e-9)
        {
         if(verbose)
            LogInfo(StringFormat("Skip: lots below min after risk calc (%.4f < min %.2f)", raw, vmin));
         return 0.0;
        }
      if(lots > vmax)
        {
         lots = NormalizeVolume(vmax);
         if(verbose)
            LogInfo(StringFormat("Lots capped to max %.2f", lots));
        }

      double free_margin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
      while(lots >= vmin - 1e-9)
        {
         double margin = 0.0;
         if(!OrderCalcMargin(type, _Symbol, lots, price, margin))
           {
            LogError(StringFormat("OrderCalcMargin failed (err %d)", GetLastError()));
            return 0.0;
           }
         if(margin <= free_margin)
            break;
         if(verbose)
            LogInfo(StringFormat("Margin %.2f > free %.2f at %.2f lots, stepping down", margin, free_margin, lots));
         lots = NormalizeVolume(lots - step);
        }
      if(lots < vmin - 1e-9)
        {
         if(verbose)
            LogInfo("Skip: lots below min after margin check");
         return 0.0;
        }
      return lots;
     }

   //--- freezing locks only (daily loss, max DD, Friday close)
   bool              IsBlocked(string &reason) const
     {
      if(m_dd_block)
        {
         reason = "Max DD";
         return true;
        }
      if(m_daily_block)
        {
         reason = "Daily loss";
         return true;
        }
      if(m_session != NULL && m_session.ShouldFridayCloseAll())
        {
         reason = "Friday close";
         return true;
        }
      reason = "";
      return false;
     }

   //--- every gate for a new entry; reason uses the log vocabulary
   bool              CanOpen(const int direction, string &reason) const
     {
      string lock;
      if(IsBlocked(lock))
        {
         reason = "blocked (" + lock + ")";
         return false;
        }
      if(m_paused)
        {
         reason = "paused by user";
         return false;
        }
      if(m_session != NULL && m_session.IsFridayNoNew())
        {
         reason = "Friday cutoff";
         return false;
        }
      if(m_session != NULL && !m_session.IsInSession())
        {
         reason = "session (outside London/NY)";
         return false;
        }
      if(!IsTradeSessionOpen())
        {
         reason = "market closed (broker trade session)";
         return false;
        }
      if(m_trades_today >= m_max_trades)
        {
         reason = StringFormat("max trades (%d/%d today)", m_trades_today, m_max_trades);
         return false;
        }
      if(!SpreadOK())
        {
         reason = StringFormat("spread (%.0f > %d points)", SpreadPoints(), m_max_spread);
         return false;
        }
      reason = (direction > 0 ? "BUY allowed" : (direction < 0 ? "SELL allowed" : "allowed"));
      return true;
     }

   bool              MustCloseAll(string &reason) const
     {
      if(m_open_count <= 0)
         return false;
      string lock;
      if(!IsBlocked(lock))
         return false;
      reason = lock;
      return true;
     }

   double            SpreadPoints(void) const
     {
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      return PriceToPoints(ask - bid);
     }
   bool              SpreadOK(void) const { return (SpreadPoints() <= (double)m_max_spread + 1e-6); }

   void              RegisterOpen(void)
     {
      m_trades_today++;
      m_history_dirty = true;
      m_state_changed = true;
     }

   void              MarkHistoryDirty(void) { m_history_dirty = true; m_state_changed = true; }

   bool              IsPaused(void) const { return m_paused; }
   void              SetPaused(const bool paused)
     {
      m_paused = paused;
      GVSet("PAUSED", paused ? 1.0 : 0.0);
      GlobalVariablesFlush();
      m_state_changed = true;
     }

   double            DailyLimit(void) const
     {
      if(m_dl_mode == DAILY_LOSS_MONEY)
         return m_dl_money;
      return m_sod_equity * m_dl_pct / 100.0;
     }

   bool              ConsumeStateChanged(void)
     {
      bool c = m_state_changed;
      m_state_changed = false;
      return c;
     }

   void              SetNote(const string note)
     {
      if(note != m_note)
         m_state_changed = true;
      m_note = note;
     }
   string            Note(void) const           { return m_note; }

   double            DailyPnL(void) const       { return m_daily_pnl; }
   double            DrawdownPct(void) const    { return m_dd_pct; }
   double            MaxDrawdownPct(void) const { return m_max_dd_pct; }
   int               TradesToday(void) const    { return m_trades_today; }
   int               MaxTrades(void) const      { return m_max_trades; }
   double            RiskPercent(void) const    { return m_risk_pct; }
   string            GVPrefix(void) const       { return m_gv; }
  };
//+------------------------------------------------------------------+
