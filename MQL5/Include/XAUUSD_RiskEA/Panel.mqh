//+------------------------------------------------------------------+
//|                                                        Panel.mqh |
//|  XAUUSD Risk EA - on-chart status panel with Close All and       |
//|  Pause/Resume. Display only: never computes lots or signals.     |
//+------------------------------------------------------------------+
#include "Utils.mqh"
#include "Session.mqh"
#include "RiskManager.mqh"
#include "TradeExecutor.mqh"

#define XRE_PANEL_ROWS 7

class CPanel
  {
private:
   CRiskManager     *m_risk;
   CSession         *m_session;
   CTradeExecutor   *m_exec;
   ENUM_BASE_CORNER  m_corner;
   int               m_x;
   int               m_y;
   int               m_font_size;
   bool              m_created;
   bool              m_poll_buttons;

   int               m_width;
   int               m_height;
   int               m_line_h;
   int               m_pad;
   int               m_btn_h;

   string            Name(const string id) const { return XRE_PREFIX + "PNL_" + id; }

   void              MakeLabel(const string id, const color clr)
     {
      string name = Name(id);
      if(ObjectFind(0, name) < 0)
         ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);
      ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(0, name, OBJPROP_ANCHOR, ANCHOR_LEFT_UPPER);
      ObjectSetString(0, name, OBJPROP_FONT, "Arial");
      ObjectSetInteger(0, name, OBJPROP_FONTSIZE, m_font_size);
      ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
      ObjectSetInteger(0, name, OBJPROP_BACK, false);
      ObjectSetInteger(0, name, OBJPROP_ZORDER, 1);
     }

   void              MakeButton(const string id, const string text)
     {
      string name = Name(id);
      if(ObjectFind(0, name) < 0)
         ObjectCreate(0, name, OBJ_BUTTON, 0, 0, 0);
      ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetString(0, name, OBJPROP_TEXT, text);
      ObjectSetString(0, name, OBJPROP_FONT, "Arial");
      ObjectSetInteger(0, name, OBJPROP_FONTSIZE, m_font_size);
      ObjectSetInteger(0, name, OBJPROP_COLOR, clrWhite);
      ObjectSetInteger(0, name, OBJPROP_BGCOLOR, C'52,58,70');
      ObjectSetInteger(0, name, OBJPROP_BORDER_COLOR, C'90,98,112');
      ObjectSetInteger(0, name, OBJPROP_STATE, false);
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
      ObjectSetInteger(0, name, OBJPROP_ZORDER, 2);
     }

   void              Place(const string id, const int x, const int y)
     {
      ObjectSetInteger(0, Name(id), OBJPROP_XDISTANCE, x);
      ObjectSetInteger(0, Name(id), OBJPROP_YDISTANCE, y);
     }

   void              SetText(const string id, const string text, const color clr)
     {
      ObjectSetString(0, Name(id), OBJPROP_TEXT, text);
      ObjectSetInteger(0, Name(id), OBJPROP_COLOR, clr);
     }

   //--- everything is laid out in left-upper coordinates; the input corner is mapped here
   void              Layout(void)
     {
      int chart_w = (int)ChartGetInteger(0, CHART_WIDTH_IN_PIXELS);
      int chart_h = (int)ChartGetInteger(0, CHART_HEIGHT_IN_PIXELS);
      int left = m_x;
      int top  = m_y;
      if(m_corner == CORNER_RIGHT_UPPER || m_corner == CORNER_RIGHT_LOWER)
         left = MathMax(0, chart_w - m_x - m_width);
      if(m_corner == CORNER_LEFT_LOWER || m_corner == CORNER_RIGHT_LOWER)
         top = MathMax(0, chart_h - m_y - m_height);

      string bg = Name("BG");
      ObjectSetInteger(0, bg, OBJPROP_XDISTANCE, left);
      ObjectSetInteger(0, bg, OBJPROP_YDISTANCE, top);
      ObjectSetInteger(0, bg, OBJPROP_XSIZE, m_width);
      ObjectSetInteger(0, bg, OBJPROP_YSIZE, m_height);

      int x = left + m_pad;
      int y = top + m_pad;
      Place("title", x, y);
      y += m_line_h + m_pad / 2;
      string rows[XRE_PANEL_ROWS - 1] = {"status", "session", "pos", "daily", "dd", "trades"};
      for(int i = 0; i < XRE_PANEL_ROWS - 1; i++)
        {
         Place(rows[i], x, y);
         y += m_line_h;
        }
      y += m_pad / 2;
      int btn_w = (m_width - 3 * m_pad) / 2;
      string btn_close = Name("btn_close"), btn_pause = Name("btn_pause");
      ObjectSetInteger(0, btn_close, OBJPROP_XDISTANCE, x);
      ObjectSetInteger(0, btn_close, OBJPROP_YDISTANCE, y);
      ObjectSetInteger(0, btn_close, OBJPROP_XSIZE, btn_w);
      ObjectSetInteger(0, btn_close, OBJPROP_YSIZE, m_btn_h);
      ObjectSetInteger(0, btn_pause, OBJPROP_XDISTANCE, x + btn_w + m_pad);
      ObjectSetInteger(0, btn_pause, OBJPROP_YDISTANCE, y);
      ObjectSetInteger(0, btn_pause, OBJPROP_XSIZE, btn_w);
      ObjectSetInteger(0, btn_pause, OBJPROP_YSIZE, m_btn_h);
      y += m_btn_h + m_pad;
      Place("footer", x, y);
     }

   void              HandleCloseAll(void)
     {
      ObjectSetInteger(0, Name("btn_close"), OBJPROP_STATE, false);
      LogInfo("Close All clicked by user on the chart panel");
      m_exec.CloseAll("user clicked Close All");
      m_risk.MarkHistoryDirty();
      Refresh();
     }

   void              HandlePause(void)
     {
      ObjectSetInteger(0, Name("btn_pause"), OBJPROP_STATE, false);
      bool pause = !m_risk.IsPaused();
      m_risk.SetPaused(pause);
      LogInfo(pause ? "Pause clicked by user on the chart panel: new entries stopped"
                    : "Resume clicked by user on the chart panel: user pause cleared");
      string lock;
      if(!pause && m_risk.IsBlocked(lock))
         LogInfo("Risk lock still active after Resume: " + lock);
      Refresh();
     }

   //--- the visual tester does not deliver OnChartEvent, so button state is polled there
   void              PollButtons(void)
     {
      if(!m_poll_buttons)
         return;
      if(ObjectGetInteger(0, Name("btn_close"), OBJPROP_STATE) != 0)
         HandleCloseAll();
      if(ObjectGetInteger(0, Name("btn_pause"), OBJPROP_STATE) != 0)
         HandlePause();
     }

public:
                     CPanel(void) : m_risk(NULL), m_session(NULL), m_exec(NULL), m_corner(CORNER_LEFT_UPPER),
                     m_x(12), m_y(24), m_font_size(9), m_created(false), m_poll_buttons(false),
                     m_width(0), m_height(0), m_line_h(0), m_pad(0), m_btn_h(0) {}

   bool              Create(CRiskManager *risk, CSession *session, CTradeExecutor *exec,
                            const ENUM_BASE_CORNER corner, const int x, const int y, const int font_size)
     {
      m_risk         = risk;
      m_session      = session;
      m_exec         = exec;
      m_corner       = corner;
      m_x            = x;
      m_y            = y;
      m_font_size    = MathMax(6, font_size);
      m_poll_buttons = (MQLInfoInteger(MQL_TESTER) != 0);

      double scale = m_font_size / 9.0;
      m_line_h = (int)MathRound(18 * scale);
      m_pad    = (int)MathRound(8 * scale);
      m_btn_h  = (int)MathRound(22 * scale);
      m_width  = (int)MathRound(290 * scale);
      m_height = m_pad + m_line_h + m_pad / 2 + (XRE_PANEL_ROWS - 1) * m_line_h + m_pad / 2 + m_btn_h + m_pad + m_line_h + m_pad;

      string bg = Name("BG");
      if(ObjectFind(0, bg) < 0)
         ObjectCreate(0, bg, OBJ_RECTANGLE_LABEL, 0, 0, 0);
      ObjectSetInteger(0, bg, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(0, bg, OBJPROP_BGCOLOR, C'24,27,34');
      ObjectSetInteger(0, bg, OBJPROP_BORDER_TYPE, BORDER_FLAT);
      ObjectSetInteger(0, bg, OBJPROP_COLOR, C'70,76,90');
      ObjectSetInteger(0, bg, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, bg, OBJPROP_HIDDEN, true);
      ObjectSetInteger(0, bg, OBJPROP_BACK, false);
      ObjectSetInteger(0, bg, OBJPROP_ZORDER, 0);

      MakeLabel("title", clrWhite);
      ObjectSetString(0, Name("title"), OBJPROP_TEXT, "XAUUSD Risk EA");
      ObjectSetInteger(0, Name("title"), OBJPROP_FONTSIZE, m_font_size + 1);
      MakeLabel("status", clrLimeGreen);
      MakeLabel("session", clrSilver);
      MakeLabel("pos", clrSilver);
      MakeLabel("daily", clrSilver);
      MakeLabel("dd", clrSilver);
      MakeLabel("trades", clrSilver);
      MakeButton("btn_close", "Close All");
      MakeButton("btn_pause", "Pause");
      MakeLabel("footer", clrGray);
      ObjectSetString(0, Name("footer"), OBJPROP_TEXT, "No profit or funded-account guarantee.");
      ObjectSetInteger(0, Name("footer"), OBJPROP_FONTSIZE, MathMax(6, m_font_size - 1));

      m_created = true;
      Layout();
      Refresh();
      return true;
     }

   void              Destroy(void)
     {
      ObjectsDeleteAll(0, XRE_PREFIX);
      m_created = false;
      ChartRedraw();
     }

   void              Refresh(void)
     {
      if(!m_created)
         return;
      PollButtons();

      string lock, status;
      color  status_clr;
      if(m_risk.IsBlocked(lock))
        {
         status     = "BLOCKED: " + lock;
         status_clr = clrTomato;
        }
      else
         if(m_risk.IsPaused())
           {
            status     = "PAUSED";
            status_clr = clrOrange;
           }
         else
           {
            status     = "ACTIVE";
            status_clr = clrLimeGreen;
           }
      if(m_risk.Note() != "")
         status += "  (" + m_risk.Note() + ")";
      SetText("status", "Status: " + status, status_clr);

      string sess = m_session.StateLabel();
      SetText("session", "Session: " + sess, sess == "Closed" || sess == "Friday cutoff" ? clrDarkGray : clrSilver);

      double floating = 0.0;
      string pos = m_exec.PositionSummary(floating);
      if(pos == "FLAT")
         SetText("pos", "Pos: FLAT 0.00", clrSilver);
      else
         SetText("pos", "Pos: " + pos + "   Float: " + FmtMoney(floating), floating >= 0.0 ? clrLimeGreen : clrTomato);

      double pnl   = m_risk.DailyPnL();
      double limit = m_risk.DailyLimit();
      SetText("daily", "Daily P/L: " + FmtMoney(pnl) + " / " + DoubleToString(-limit, 2),
              (limit > 0.0 && pnl <= -0.75 * limit) ? clrOrange : clrSilver);

      double dd = m_risk.DrawdownPct();
      SetText("dd", StringFormat("DD: %.1f%% / %.1f%%", dd, m_risk.MaxDrawdownPct()),
              dd >= 0.75 * m_risk.MaxDrawdownPct() ? clrOrange : clrSilver);

      SetText("trades", StringFormat("Trades today: %d / %d", m_risk.TradesToday(), m_risk.MaxTrades()),
              m_risk.TradesToday() >= m_risk.MaxTrades() ? clrOrange : clrSilver);

      ObjectSetString(0, Name("btn_pause"), OBJPROP_TEXT, m_risk.IsPaused() ? "Resume" : "Pause");
      ChartRedraw();
     }

   void              OnChartEvent(const int id, const long &lparam, const double &dparam, const string &sparam)
     {
      if(!m_created)
         return;
      if(id == CHARTEVENT_OBJECT_CLICK)
        {
         if(sparam == Name("btn_close"))
            HandleCloseAll();
         else
            if(sparam == Name("btn_pause"))
               HandlePause();
        }
      else
         if(id == CHARTEVENT_CHART_CHANGE)
           {
            Layout();
            ChartRedraw();
           }
     }
  };
//+------------------------------------------------------------------+
