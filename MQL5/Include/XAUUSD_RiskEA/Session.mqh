//+------------------------------------------------------------------+
//|                                                      Session.mqh |
//|        XAUUSD Risk EA - London / New York windows, Friday rules   |
//+------------------------------------------------------------------+
#include "Utils.mqh"

class CSession
  {
private:
   int               m_offset;
   bool              m_use_london;
   bool              m_use_ny;
   int               m_lon_start;
   int               m_lon_end;
   int               m_ny_start;
   int               m_ny_end;
   int               m_fri_no_new;
   bool              m_fri_close_all;
   int               m_fri_close;

   //--- end is exclusive; windows crossing midnight are supported
   bool              InWindow(const int minute, const int start, const int end) const
     {
      if(start <= end)
         return (minute >= start && minute < end);
      return (minute >= start || minute < end);
     }

   void              GmtParts(int &dow, int &minute) const
     {
      MqlDateTime dt;
      TimeToStruct(GmtTime(m_offset), dt);
      dow    = dt.day_of_week;
      minute = dt.hour * 60 + dt.min;
     }

public:
                     CSession(void) : m_offset(0), m_use_london(true), m_use_ny(true),
                     m_lon_start(0), m_lon_end(0), m_ny_start(0), m_ny_end(0),
                     m_fri_no_new(0), m_fri_close_all(true), m_fri_close(0) {}

   void              Init(const int server_gmt_offset,
                          const bool use_london, const int lon_sh, const int lon_sm, const int lon_eh, const int lon_em,
                          const bool use_ny, const int ny_sh, const int ny_sm, const int ny_eh, const int ny_em,
                          const int fri_no_new_h, const int fri_no_new_m,
                          const bool fri_close_all, const int fri_close_h, const int fri_close_m)
     {
      m_offset        = server_gmt_offset;
      m_use_london    = use_london;
      m_lon_start     = lon_sh * 60 + lon_sm;
      m_lon_end       = lon_eh * 60 + lon_em;
      m_use_ny        = use_ny;
      m_ny_start      = ny_sh * 60 + ny_sm;
      m_ny_end        = ny_eh * 60 + ny_em;
      m_fri_no_new    = fri_no_new_h * 60 + fri_no_new_m;
      m_fri_close_all = fri_close_all;
      m_fri_close     = fri_close_h * 60 + fri_close_m;
     }

   bool              IsLondon(void) const
     {
      int dow, minute;
      GmtParts(dow, minute);
      if(dow == 0 || dow == 6)
         return false;
      return (m_use_london && InWindow(minute, m_lon_start, m_lon_end));
     }

   bool              IsNewYork(void) const
     {
      int dow, minute;
      GmtParts(dow, minute);
      if(dow == 0 || dow == 6)
         return false;
      return (m_use_ny && InWindow(minute, m_ny_start, m_ny_end));
     }

   bool              IsInSession(void) const { return (IsLondon() || IsNewYork()); }

   //--- Friday from the no-new time through the weekend
   bool              IsFridayNoNew(void) const
     {
      int dow, minute;
      GmtParts(dow, minute);
      if(dow == 6 || dow == 0)
         return true;
      return (dow == 5 && minute >= m_fri_no_new);
     }

   //--- Friday from the close-all time through the weekend (only if enabled)
   bool              ShouldFridayCloseAll(void) const
     {
      if(!m_fri_close_all)
         return false;
      int dow, minute;
      GmtParts(dow, minute);
      if(dow == 6 || dow == 0)
         return true;
      return (dow == 5 && minute >= m_fri_close);
     }

   string            StateLabel(void) const
     {
      if(IsFridayNoNew())
         return "Friday cutoff";
      bool lon = IsLondon();
      bool ny  = IsNewYork();
      if(lon && ny)
         return "London+NY";
      if(lon)
         return "London";
      if(ny)
         return "New York";
      return "Closed";
     }
  };
//+------------------------------------------------------------------+
