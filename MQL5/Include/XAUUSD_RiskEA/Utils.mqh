//+------------------------------------------------------------------+
//|                                                        Utils.mqh |
//|                     XAUUSD Risk EA - logging, time, price helpers |
//+------------------------------------------------------------------+
#define XRE_PREFIX "XAU_RISK_EA_"

enum ENUM_LOG_LEVEL
  {
   LOG_ERROR = 0,
   LOG_INFO  = 1,
   LOG_DEBUG = 2
  };

ENUM_LOG_LEVEL g_log_level = LOG_INFO;

//--- yyyy.mm.dd hh:mm:ss [LEVEL] message
void LogWrite(const string level, const string msg)
  {
   Print(TimeToString(TimeCurrent(), TIME_DATE | TIME_SECONDS), " [", level, "] ", msg);
  }

void LogError(const string msg) { LogWrite("ERR", msg); }
void LogInfo(const string msg)  { if(g_log_level >= LOG_INFO)  LogWrite("INFO", msg); }
void LogDebug(const string msg) { if(g_log_level >= LOG_DEBUG) LogWrite("DEBUG", msg); }

//--- server time shifted back to GMT (server = GMT + offset)
datetime GmtTime(const int server_gmt_offset)
  {
   return (datetime)((long)TimeCurrent() - (long)server_gmt_offset * 3600);
  }

//--- 00:00 of the current server date
datetime ServerMidnight()
  {
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   dt.hour = 0;
   dt.min  = 0;
   dt.sec  = 0;
   return StructToTime(dt);
  }

//--- yyyymmdd key of a datetime
int DateKey(const datetime t)
  {
   MqlDateTime dt;
   TimeToStruct(t, dt);
   return dt.year * 10000 + dt.mon * 100 + dt.day;
  }

//--- true on the first tick of a new bar; the first call only primes the state
bool IsNewBar(const ENUM_TIMEFRAMES tf)
  {
   static int      s_tf[8];
   static datetime s_time[8];
   static int      s_count = 0;

   datetime bar = iTime(_Symbol, tf, 0);
   if(bar == 0)
      return false;

   for(int i = 0; i < s_count; i++)
     {
      if(s_tf[i] != (int)tf)
         continue;
      if(s_time[i] == bar)
         return false;
      s_time[i] = bar;
      return true;
     }

   if(s_count < 8)
     {
      s_tf[s_count]   = (int)tf;
      s_time[s_count] = bar;
      s_count++;
     }
   return false;
  }

int VolumeDigits(const double step)
  {
   int d = 0;
   while(d < 8)
     {
      double scaled = step * MathPow(10.0, d);
      if(MathAbs(scaled - MathRound(scaled)) < 1e-8)
         break;
      d++;
     }
   return d;
  }

//--- floor to SYMBOL_VOLUME_STEP; never rounds up
double NormalizeVolume(const double lots)
  {
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(step <= 0.0 || lots <= 0.0)
      return 0.0;
   double v = MathFloor(lots / step + 1e-8) * step;
   return NormalizeDouble(v, VolumeDigits(step));
  }

//--- align a price to the tick grid; mode -1 = floor, 0 = nearest, +1 = ceil
double NormalizePrice(const double price, const int mode = 0)
  {
   double tick = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tick <= 0.0)
      tick = _Point;
   double units = price / tick;
   double aligned;
   if(mode < 0)
      aligned = MathFloor(units + 1e-8);
   else
      if(mode > 0)
         aligned = MathCeil(units - 1e-8);
      else
         aligned = MathRound(units);
   return NormalizeDouble(aligned * tick, _Digits);
  }

//--- round a positive distance up to a whole number of ticks
double CeilToTick(const double distance)
  {
   double tick = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tick <= 0.0)
      tick = _Point;
   return NormalizeDouble(MathCeil(distance / tick - 1e-8) * tick, _Digits);
  }

double PointsToPrice(const double points) { return points * _Point; }
double PriceToPoints(const double price)  { return (_Point > 0.0) ? price / _Point : 0.0; }

//--- broker minimum SL/TP distance: (max(stops level, freeze level) + 1) points
double MinStopDistance()
  {
   long stops  = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   long freeze = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL);
   return (double)(MathMax(stops, freeze) + 1) * _Point;
  }

//--- broker trade session for the current server time; ticks can still arrive during the daily break
bool IsTradeSessionOpen()
  {
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   datetime now_sec = (datetime)(dt.hour * 3600 + dt.min * 60 + dt.sec);
   datetime from = 0, to = 0;
   for(uint i = 0; SymbolInfoSessionTrade(_Symbol, (ENUM_DAY_OF_WEEK)dt.day_of_week, i, from, to); i++)
     {
      if(now_sec >= from && now_sec < to)
         return true;
     }
   return false;
  }

string FmtMoney(const double v)
  {
   return (v >= 0.0 ? "+" : "") + DoubleToString(v, 2);
  }

string FmtPrice(const double p)
  {
   return DoubleToString(p, _Digits);
  }
//+------------------------------------------------------------------+
