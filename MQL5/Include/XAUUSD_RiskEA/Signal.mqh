//+------------------------------------------------------------------+
//|                                                       Signal.mqh |
//|     XAUUSD Risk EA - H1 EMA trend filter + M15 EMA pullback entry |
//|     Closed bars only: shift 1 and shift 2, never shift 0.         |
//+------------------------------------------------------------------+
#include "Utils.mqh"

enum ENUM_SIGNAL
  {
   SIGNAL_NONE = 0,
   SIGNAL_BUY  = 1,
   SIGNAL_SELL = -1
  };

enum ENUM_TREND
  {
   TREND_NEUTRAL = 0,
   TREND_BULL    = 1,
   TREND_BEAR    = -1
  };

class CSignal
  {
private:
   int               h_ema_fast_h1;
   int               h_ema_slow_h1;
   int               h_ema_m15;
   int               h_atr_m15;
   double            m_max_ext_atr;
   bool              m_allow_buy;
   bool              m_allow_sell;

   double            m_last_atr;
   double            m_last_ema;
   string            m_last_reason;
   string            m_trend_reason;

   datetime          m_cache_bar;
   double            m_cache_atr;
   double            m_cache_close;

   //--- three closed values: buf[0] = shift 1, buf[1] = shift 2, buf[2] = shift 3
   bool              Copy3(const int handle, double &buf[])
     {
      ArraySetAsSeries(buf, true);
      return (CopyBuffer(handle, 0, 1, 3, buf) == 3);
     }

   bool              CheckBuy(const MqlRates &bar, const double ema, const double atr, string &why) const
     {
      if(!(bar.low <= ema && bar.close > ema))
        {
         why = StringFormat("no touch (low=%s close=%s ema=%s)", FmtPrice(bar.low), FmtPrice(bar.close), FmtPrice(ema));
         return false;
        }
      if(!(bar.close > bar.open))
        {
         why = "no bullish confirmation candle";
         return false;
        }
      if(!(atr > 0.0))
        {
         why = "ATR not positive";
         return false;
        }
      if((bar.close - ema) > m_max_ext_atr * atr)
        {
         why = StringFormat("extended (close-ema=%s > %.2f*ATR=%s)", FmtPrice(bar.close - ema), m_max_ext_atr, FmtPrice(m_max_ext_atr * atr));
         return false;
        }
      why = StringFormat("touch low=%s<=ema=%s, close=%s>open=%s, ext=%s<=%s",
                         FmtPrice(bar.low), FmtPrice(ema), FmtPrice(bar.close), FmtPrice(bar.open),
                         FmtPrice(bar.close - ema), FmtPrice(m_max_ext_atr * atr));
      return true;
     }

   bool              CheckSell(const MqlRates &bar, const double ema, const double atr, string &why) const
     {
      if(!(bar.high >= ema && bar.close < ema))
        {
         why = StringFormat("no touch (high=%s close=%s ema=%s)", FmtPrice(bar.high), FmtPrice(bar.close), FmtPrice(ema));
         return false;
        }
      if(!(bar.close < bar.open))
        {
         why = "no bearish confirmation candle";
         return false;
        }
      if(!(atr > 0.0))
        {
         why = "ATR not positive";
         return false;
        }
      if((ema - bar.close) > m_max_ext_atr * atr)
        {
         why = StringFormat("extended (ema-close=%s > %.2f*ATR=%s)", FmtPrice(ema - bar.close), m_max_ext_atr, FmtPrice(m_max_ext_atr * atr));
         return false;
        }
      why = StringFormat("touch high=%s>=ema=%s, close=%s<open=%s, ext=%s<=%s",
                         FmtPrice(bar.high), FmtPrice(ema), FmtPrice(bar.close), FmtPrice(bar.open),
                         FmtPrice(ema - bar.close), FmtPrice(m_max_ext_atr * atr));
      return true;
     }

public:
                     CSignal(void) : h_ema_fast_h1(INVALID_HANDLE), h_ema_slow_h1(INVALID_HANDLE),
                     h_ema_m15(INVALID_HANDLE), h_atr_m15(INVALID_HANDLE),
                     m_max_ext_atr(0.5), m_allow_buy(true), m_allow_sell(true),
                     m_last_atr(0.0), m_last_ema(0.0), m_last_reason(""), m_trend_reason(""),
                     m_cache_bar(0), m_cache_atr(0.0), m_cache_close(0.0) {}

   bool              Init(const int h1_fast, const int h1_slow, const int m15_ema, const int atr_period,
                          const double max_ext_atr, const bool allow_buy, const bool allow_sell)
     {
      m_max_ext_atr = max_ext_atr;
      m_allow_buy   = allow_buy;
      m_allow_sell  = allow_sell;

      h_ema_fast_h1 = iMA(_Symbol, PERIOD_H1, h1_fast, 0, MODE_EMA, PRICE_CLOSE);
      h_ema_slow_h1 = iMA(_Symbol, PERIOD_H1, h1_slow, 0, MODE_EMA, PRICE_CLOSE);
      h_ema_m15     = iMA(_Symbol, PERIOD_M15, m15_ema, 0, MODE_EMA, PRICE_CLOSE);
      h_atr_m15     = iATR(_Symbol, PERIOD_M15, atr_period);

      if(h_ema_fast_h1 == INVALID_HANDLE || h_ema_slow_h1 == INVALID_HANDLE ||
         h_ema_m15 == INVALID_HANDLE || h_atr_m15 == INVALID_HANDLE)
        {
         LogError(StringFormat("Indicator handle creation failed (err %d)", GetLastError()));
         return false;
        }
      return true;
     }

   void              Release(void)
     {
      if(h_ema_fast_h1 != INVALID_HANDLE) { IndicatorRelease(h_ema_fast_h1); h_ema_fast_h1 = INVALID_HANDLE; }
      if(h_ema_slow_h1 != INVALID_HANDLE) { IndicatorRelease(h_ema_slow_h1); h_ema_slow_h1 = INVALID_HANDLE; }
      if(h_ema_m15 != INVALID_HANDLE)     { IndicatorRelease(h_ema_m15);     h_ema_m15 = INVALID_HANDLE; }
      if(h_atr_m15 != INVALID_HANDLE)     { IndicatorRelease(h_atr_m15);     h_atr_m15 = INVALID_HANDLE; }
     }

   //--- evaluated on the last two closed H1 bars; equality is never a trend
   ENUM_TREND        TrendState(void)
     {
      double fast[], slow[];
      if(!Copy3(h_ema_fast_h1, fast) || !Copy3(h_ema_slow_h1, slow))
        {
         m_trend_reason = "H1 EMA data not ready";
         return TREND_NEUTRAL;
        }
      if(fast[0] > slow[0] && slow[0] > slow[1])
        {
         m_trend_reason = StringFormat("H1 bull (EMAf=%s > EMAs=%s, EMAs rising from %s)", FmtPrice(fast[0]), FmtPrice(slow[0]), FmtPrice(slow[1]));
         return TREND_BULL;
        }
      if(fast[0] < slow[0] && slow[0] < slow[1])
        {
         m_trend_reason = StringFormat("H1 bear (EMAf=%s < EMAs=%s, EMAs falling from %s)", FmtPrice(fast[0]), FmtPrice(slow[0]), FmtPrice(slow[1]));
         return TREND_BEAR;
        }
      m_trend_reason = StringFormat("neutral (H1 EMAf=%s EMAs=%s EMAs[2]=%s)", FmtPrice(fast[0]), FmtPrice(slow[0]), FmtPrice(slow[1]));
      return TREND_NEUTRAL;
     }

   //--- called once on the first tick of a new M15 bar
   ENUM_SIGNAL       CheckClosedBar(void)
     {
      m_last_atr    = 0.0;
      m_last_ema    = 0.0;
      m_last_reason = "";

      ENUM_TREND trend = TrendState();
      if(trend == TREND_NEUTRAL)
        {
         m_last_reason = m_trend_reason;
         LogDebug("Signal: none - " + m_last_reason);
         return SIGNAL_NONE;
        }

      double ema[], atr[];
      if(!Copy3(h_ema_m15, ema) || !Copy3(h_atr_m15, atr))
        {
         m_last_reason = "M15 indicator data not ready";
         LogDebug("Signal: none - " + m_last_reason);
         return SIGNAL_NONE;
        }

      MqlRates rates[];
      ArraySetAsSeries(rates, true);
      if(CopyRates(_Symbol, PERIOD_M15, 1, 1, rates) != 1)
        {
         m_last_reason = "M15 rates not ready";
         LogDebug("Signal: none - " + m_last_reason);
         return SIGNAL_NONE;
        }

      MqlRates bar = rates[0];
      m_last_ema = ema[0];
      m_last_atr = atr[0];

      string why_buy = "not evaluated", why_sell = "not evaluated";
      bool buy  = false;
      bool sell = false;

      if(trend == TREND_BULL)
        {
         if(m_allow_buy)
            buy = CheckBuy(bar, m_last_ema, m_last_atr, why_buy);
         else
            why_buy = "buys disabled";
        }
      if(trend == TREND_BEAR)
        {
         if(m_allow_sell)
            sell = CheckSell(bar, m_last_ema, m_last_atr, why_sell);
         else
            why_sell = "sells disabled";
        }

      if(buy && sell)
        {
         m_last_reason = "both sides passed - ignored";
         LogError("Signal: both BUY and SELL passed on the same bar; taking neither");
         return SIGNAL_NONE;
        }

      string atr_txt = "ATR=" + FmtPrice(m_last_atr);
      if(buy)
        {
         m_last_reason = m_trend_reason + "; " + why_buy + "; " + atr_txt;
         LogDebug("Signal: BUY - " + m_last_reason);
         return SIGNAL_BUY;
        }
      if(sell)
        {
         m_last_reason = m_trend_reason + "; " + why_sell + "; " + atr_txt;
         LogDebug("Signal: SELL - " + m_last_reason);
         return SIGNAL_SELL;
        }

      m_last_reason = m_trend_reason + "; " + (trend == TREND_BULL ? why_buy : why_sell);
      LogDebug("Signal: none - " + m_last_reason);
      return SIGNAL_NONE;
     }

   //--- closed-bar ATR and close for trailing, cached per M15 bar
   bool              ClosedBarAtrClose(double &atr, double &close)
     {
      datetime bar0 = iTime(_Symbol, PERIOD_M15, 0);
      if(bar0 != 0 && bar0 == m_cache_bar && m_cache_atr > 0.0)
        {
         atr   = m_cache_atr;
         close = m_cache_close;
         return true;
        }
      double buf[];
      if(!Copy3(h_atr_m15, buf))
         return false;
      double c = iClose(_Symbol, PERIOD_M15, 1);
      if(c <= 0.0 || buf[0] <= 0.0)
         return false;
      m_cache_bar   = bar0;
      m_cache_atr   = buf[0];
      m_cache_close = c;
      atr   = m_cache_atr;
      close = m_cache_close;
      return true;
     }

   double            LastATR(void) const      { return m_last_atr; }
   double            LastEntryEMA(void) const { return m_last_ema; }
   string            LastReason(void) const   { return m_last_reason; }
  };
//+------------------------------------------------------------------+
