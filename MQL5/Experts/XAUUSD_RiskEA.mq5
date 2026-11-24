//+------------------------------------------------------------------+
//|                                                XAUUSD_RiskEA.mq5 |
//|  XAUUSD M15 Expert Advisor: H1 EMA trend filter, M15 EMA pullback |
//|  entry, risk-% sizing, daily loss / max DD locks, session and    |
//|  Friday rules, break-even + ATR trail, on-chart panel.           |
//|  Coding showcase - no profit, drawdown or funded-account claims. |
//+------------------------------------------------------------------+
#property copyright "Ugo Coppola"
#property version   "1.00"
#property description "XAUUSD M15 pullback EA with risk engine and on-chart panel."
#property description "Coding portfolio piece. No profit, drawdown or funded-account guarantee."

#include <XAUUSD_RiskEA/Utils.mqh>
#include <XAUUSD_RiskEA/Session.mqh>
#include <XAUUSD_RiskEA/Signal.mqh>
#include <XAUUSD_RiskEA/RiskManager.mqh>
#include <XAUUSD_RiskEA/TradeExecutor.mqh>
#include <XAUUSD_RiskEA/Panel.mqh>

//--- inputs
input group "Execution"
input ulong            InpMagic              = 20261125;          // Magic number
input string           InpTradeComment       = "XAU_RISK_EA";     // Trade comment
input int              InpSlippagePoints     = 30;                // Max slippage (points)
input bool             InpAllowBuy           = true;              // Allow buys
input bool             InpAllowSell          = true;              // Allow sells

input group "Strategy"
input int              InpH1FastEMA          = 50;                // H1 fast EMA period
input int              InpH1SlowEMA          = 200;               // H1 slow EMA period (> fast)
input int              InpM15EntryEMA        = 21;                // M15 pullback EMA period
input int              InpATRPeriod          = 14;                // M15 ATR period
input double           InpSLATRMult          = 1.5;               // SL distance = ATR x
input double           InpRiskReward         = 2.0;               // TP = SL distance x RR
input double           InpMaxExtensionATR    = 0.5;               // Skip if close is farther than ATR x from EMA

input group "Risk"
input double           InpRiskPercent        = 0.5;               // Risk per trade (% of equity)
input double           InpMaxLot             = 0.0;               // Max lot (0 = symbol max)
input ENUM_DAILY_LOSS_MODE InpDailyLossMode  = DAILY_LOSS_PERCENT; // Daily loss mode
input double           InpDailyLossPercent   = 2.0;               // Daily loss limit (% of start-of-day equity)
input double           InpDailyLossMoney     = 0.0;               // Daily loss limit (account currency)
input double           InpMaxDrawdownPercent = 6.0;               // Max drawdown from equity high (%)
input int              InpMaxTradesPerDay    = 4;                 // Max entries per day
input int              InpMaxSpreadPoints    = 50;                // Max spread (points)
input double           InpBE_R               = 1.0;               // Break-even after R
input int              InpBEBufferPoints     = 20;                // Break-even buffer (points)
input double           InpTrailStartR        = 1.0;               // Start ATR trail after R
input double           InpTrailATRMult       = 1.0;               // Trail distance = ATR x
input bool             InpClearRiskLocks     = false;             // Clear daily-loss / max-DD locks on init

input group "Session"
input int              InpServerGmtOffset    = 2;                 // Server GMT offset (server = GMT + offset)
input bool             InpUseLondon          = true;              // Trade London session
input bool             InpUseNewYork         = true;              // Trade New York session
input int              InpLondonStartHour    = 7;                 // London start hour (GMT)
input int              InpLondonStartMin     = 0;                 // London start minute
input int              InpLondonEndHour      = 16;                // London end hour (GMT, exclusive)
input int              InpLondonEndMin       = 0;                 // London end minute
input int              InpNYStartHour        = 12;                // New York start hour (GMT)
input int              InpNYStartMin         = 0;                 // New York start minute
input int              InpNYEndHour          = 21;                // New York end hour (GMT, exclusive)
input int              InpNYEndMin           = 0;                 // New York end minute
input int              InpFridayNoNewHour    = 16;                // Friday no new entries from hour (GMT)
input int              InpFridayNoNewMin     = 0;                 // Friday no new entries from minute
input bool             InpFridayCloseAll     = true;              // Friday close all positions
input int              InpFridayCloseHour    = 16;                // Friday close-all hour (GMT)
input int              InpFridayCloseMin     = 30;                // Friday close-all minute

input group "Panel"
input bool             InpShowPanel          = true;              // Show on-chart panel
input ENUM_BASE_CORNER InpPanelCorner        = CORNER_LEFT_UPPER; // Panel corner
input int              InpPanelX             = 12;                // Panel X offset (px)
input int              InpPanelY             = 24;                // Panel Y offset (px)
input int              InpPanelFontSize      = 9;                 // Panel font size
input int              InpTimerSec           = 1;                 // Panel refresh (seconds, min 1)

input group "Logging"
input ENUM_LOG_LEVEL   InpLogLevel           = LOG_INFO;          // Log level

//--- modules
CSession        g_session;
CSignal         g_signal;
CRiskManager    g_risk;
CTradeExecutor  g_exec;
CPanel          g_panel;
bool            g_panel_on = false;

//+------------------------------------------------------------------+
bool Fail(const string why)
  {
   LogError("Init failed: " + why);
   return false;
  }

bool ValidHour(const int h)   { return (h >= 0 && h <= 23); }
bool ValidMinute(const int m) { return (m >= 0 && m <= 59); }

bool ValidateInputs()
  {
   if(InpH1FastEMA <= 0 || InpH1SlowEMA <= 0 || InpM15EntryEMA <= 0 || InpATRPeriod <= 0)
      return Fail("indicator periods must be > 0");
   if(InpH1SlowEMA <= InpH1FastEMA)
      return Fail("InpH1SlowEMA must be greater than InpH1FastEMA");
   if(InpSLATRMult <= 0.0)
      return Fail("InpSLATRMult must be > 0");
   if(InpRiskReward <= 0.0)
      return Fail("InpRiskReward must be > 0");
   if(InpRiskPercent <= 0.0 || InpRiskPercent > 5.0)
      return Fail("InpRiskPercent must be in (0, 5]");
   if(InpDailyLossPercent <= 0.0 || InpDailyLossPercent > 50.0)
      return Fail("InpDailyLossPercent must be in (0, 50]");
   if(InpDailyLossMode == DAILY_LOSS_MONEY && InpDailyLossMoney <= 0.0)
      return Fail("InpDailyLossMoney must be > 0 when InpDailyLossMode = DAILY_LOSS_MONEY");
   if(InpMaxDrawdownPercent <= 0.0 || InpMaxDrawdownPercent > 50.0)
      return Fail("InpMaxDrawdownPercent must be in (0, 50]");
   if(InpMaxTradesPerDay < 1)
      return Fail("InpMaxTradesPerDay must be >= 1");
   if(!ValidHour(InpLondonStartHour) || !ValidHour(InpLondonEndHour) || !ValidHour(InpNYStartHour) ||
      !ValidHour(InpNYEndHour) || !ValidHour(InpFridayNoNewHour) || !ValidHour(InpFridayCloseHour))
      return Fail("hours must be 0-23");
   if(!ValidMinute(InpLondonStartMin) || !ValidMinute(InpLondonEndMin) || !ValidMinute(InpNYStartMin) ||
      !ValidMinute(InpNYEndMin) || !ValidMinute(InpFridayNoNewMin) || !ValidMinute(InpFridayCloseMin))
      return Fail("minutes must be 0-59");
   if(InpFridayCloseHour * 60 + InpFridayCloseMin < InpFridayNoNewHour * 60 + InpFridayNoNewMin)
      return Fail("Friday close time must be >= Friday no-new time");
   if(InpTimerSec < 1)
      return Fail("InpTimerSec must be >= 1");
   return true;
  }

bool HistoryReady(const ENUM_TIMEFRAMES tf, const int needed)
  {
   int bars = 0;
   for(int attempt = 0; attempt < 10; attempt++)
     {
      bars = Bars(_Symbol, tf);
      if(bars >= needed)
         return true;
      Sleep(200);
     }
   LogError(StringFormat("Not enough %s history: %d bars, need %d", EnumToString(tf), bars, needed));
   return false;
  }

void RefreshPanel()
  {
   if(g_panel_on)
      g_panel.Refresh();
  }

//+------------------------------------------------------------------+
int OnInit()
  {
   g_log_level = InpLogLevel;

   if(_Period != PERIOD_M15)
     {
      Fail("attach the EA to an M15 chart (current: " + EnumToString((ENUM_TIMEFRAMES)_Period) + ")");
      return INIT_FAILED;
     }
   string sym = _Symbol;
   StringToUpper(sym);
   if(StringFind(sym, "XAU") < 0 && StringFind(sym, "GOLD") < 0)
      LogInfo("WARNING: symbol " + _Symbol + " does not look like XAUUSD/GOLD; continuing");

   if(!ValidateInputs())
      return INIT_FAILED;

   if(!AccountInfoInteger(ACCOUNT_TRADE_EXPERT))
     {
      Fail("expert trading is disabled for this account");
      return INIT_FAILED;
     }
   if((ENUM_SYMBOL_TRADE_MODE)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_MODE) == SYMBOL_TRADE_MODE_DISABLED)
     {
      Fail("symbol " + _Symbol + " is not tradable");
      return INIT_FAILED;
     }
   if(!HistoryReady(PERIOD_H1, InpH1SlowEMA + 5) ||
      !HistoryReady(PERIOD_M15, MathMax(InpM15EntryEMA, InpATRPeriod) + 5))
     {
      Fail("insufficient history");
      return INIT_FAILED;
     }

   g_session.Init(InpServerGmtOffset,
                  InpUseLondon, InpLondonStartHour, InpLondonStartMin, InpLondonEndHour, InpLondonEndMin,
                  InpUseNewYork, InpNYStartHour, InpNYStartMin, InpNYEndHour, InpNYEndMin,
                  InpFridayNoNewHour, InpFridayNoNewMin,
                  InpFridayCloseAll, InpFridayCloseHour, InpFridayCloseMin);

   if(!g_signal.Init(InpH1FastEMA, InpH1SlowEMA, InpM15EntryEMA, InpATRPeriod,
                     InpMaxExtensionATR, InpAllowBuy, InpAllowSell))
     {
      Fail("indicator handles");
      return INIT_FAILED;
     }

   if(!g_risk.Init(InpMagic, InpRiskPercent, InpMaxLot, InpDailyLossMode, InpDailyLossPercent, InpDailyLossMoney,
                   InpMaxDrawdownPercent, InpMaxTradesPerDay, InpMaxSpreadPoints, GetPointer(g_session), InpClearRiskLocks))
     {
      Fail("risk manager");
      return INIT_FAILED;
     }

   g_exec.Init(GetPointer(g_risk), InpMagic, InpTradeComment, InpSlippagePoints, InpSLATRMult, InpRiskReward,
               InpBE_R, InpBEBufferPoints, InpTrailStartR, InpTrailATRMult);

   //--- the panel is skipped in non-visual tester runs (nothing to look at, saves time)
   bool tester_hidden = (MQLInfoInteger(MQL_TESTER) != 0 && MQLInfoInteger(MQL_VISUAL_MODE) == 0);
   g_panel_on = (InpShowPanel && !tester_hidden);
   if(g_panel_on)
     {
      g_panel.Create(GetPointer(g_risk), GetPointer(g_session), GetPointer(g_exec),
                     InpPanelCorner, InpPanelX, InpPanelY, InpPanelFontSize);
      EventSetTimer(InpTimerSec);
     }

   IsNewBar(PERIOD_M15);
   LogInfo(StringFormat("XAUUSD Risk EA started on %s M15: magic=%I64u risk=%.2f%% daily loss=%s max DD=%.1f%% max trades=%d GMT offset=%+d",
                        _Symbol, InpMagic, InpRiskPercent,
                        InpDailyLossMode == DAILY_LOSS_PERCENT ? DoubleToString(InpDailyLossPercent, 2) + "%" : DoubleToString(InpDailyLossMoney, 2),
                        InpMaxDrawdownPercent, InpMaxTradesPerDay, InpServerGmtOffset));
   return INIT_SUCCEEDED;
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   EventKillTimer();
   g_panel.Destroy();
   g_signal.Release();
   g_risk.Deinit(reason, InpClearRiskLocks);
  }

//+------------------------------------------------------------------+
void OnNewBar()
  {
   g_risk.SetNote("");

   ENUM_SIGNAL signal = g_signal.CheckClosedBar();
   string gate;
   bool   allowed = g_risk.CanOpen((int)signal, gate);

   if(signal == SIGNAL_NONE)
     {
      if(!allowed)
         LogDebug("Bar gate: " + gate);
      return;
     }

   string side = (signal == SIGNAL_BUY) ? "BUY" : "SELL";
   if(!allowed)
     {
      LogInfo(side + " signal skipped: " + gate + " | " + g_signal.LastReason());
      if(StringFind(gate, "spread") == 0)
         g_risk.SetNote("Spread");
      return;
     }

   if(g_exec.Open(signal, g_signal.LastATR(), g_signal.LastReason()))
     {
      g_risk.RegisterOpen();
      RefreshPanel();
     }
  }

//+------------------------------------------------------------------+
void OnTick()
  {
   g_risk.Update();

   string reason;
   if(g_risk.MustCloseAll(reason))
     {
      g_exec.CloseAll(reason);
      g_risk.MarkHistoryDirty();
      RefreshPanel();
      return;
     }

   if(g_exec.CountAll() > 0)
     {
      double atr1 = 0.0, close1 = 0.0;
      if(g_signal.ClosedBarAtrClose(atr1, close1))
         g_exec.ManagePositions(atr1, close1);
      else
         g_exec.ManageBreakEven();
     }

   if(IsNewBar(PERIOD_M15))
      OnNewBar();

   if(g_risk.ConsumeStateChanged())
      RefreshPanel();
  }

//+------------------------------------------------------------------+
void OnTrade()
  {
   g_risk.MarkHistoryDirty();
   g_exec.CleanupInitialSL();
  }

//+------------------------------------------------------------------+
void OnTimer()
  {
   RefreshPanel();
  }

//+------------------------------------------------------------------+
void OnChartEvent(const int id, const long &lparam, const double &dparam, const string &sparam)
  {
   if(g_panel_on)
      g_panel.OnChartEvent(id, lparam, dparam, sparam);
  }
//+------------------------------------------------------------------+
