//+------------------------------------------------------------------+
//|                                             PropRulesMonitor.mq5 |
//|                                      Copyright 2026, Allan Niñal |
//|                                  https://www.allanninal.dev/mql5 |
//+------------------------------------------------------------------+
//| Free indicator: shows how close the account is to its prop-firm  |
//| daily loss limit and max loss, live, with alerts at a warning    |
//| level and at a breach. It only watches: it never opens, closes   |
//| or changes a trade, so it works without Algo Trading. The rules  |
//| are typed in by the user. Engine: MonEngine.mqh.                 |
//|                                                                  |
//+------------------------------------------------------------------+
// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0 (see LICENSE)
#property copyright "Copyright 2026, Allan Niñal <https://www.allanninal.dev/mql5>"
#property link      "https://www.allanninal.dev/mql5"
#property version   "1.01"
#property description "Live prop-firm rule monitor: daily loss limit and max loss (static or trailing) measured on equity, with the firm's reset time and zone."
#property description "Warning and breach alerts. Watches only - never trades."
#property indicator_chart_window
#property indicator_buffers 0
#property indicator_plots   0

#include <PropRulesMonitor/MonView.mqh>

input group "DAILY LOSS LIMIT"
input double        InpDailyPct   = 5.0;               // Daily loss limit, % (0 = off)
input ENUM_PRG_OF   InpDailyOf    = PRG_OF_INITIAL;    // Limit is
input ENUM_PRG_REF  InpDailyRef   = PRG_REF_BALANCE;   // Measured from
input ENUM_PRG_ZONE InpResetZone  = PRG_ZONE_PRAGUE;   // Day resets in time zone
input int           InpResetHour  = 0;                 // Day resets at hour (0-23)

input group "MAX LOSS"
input double        InpMaxPct     = 10.0;              // Max loss, % of account size (0 = off)
input ENUM_PRG_MAX  InpMaxMode    = PRG_MAX_STATIC;    // Max loss type
input bool          InpMaxStop    = false;             // Trailing floor stops at the account size
input double        InpSmartGain  = 5.0;               // Two-stage: after a closed gain of %
input double        InpSmartAfter = 5.0;               // Two-stage: max loss becomes %

input group "ACCOUNT"
input double        InpAccount    = 0;                 // Account size (0 = first deposit)
input double        InpTargetPct  = 10.0;              // Profit target, % (0 = none)
input int           InpMinDays    = 4;                 // Minimum trading days (0 = none)

input group "ALERTS (MetaTrader push settings)"
input double        InpWarnAt     = 80;                // Warn at % of a limit used
input bool          InpPopup      = true;              // Pop-up alert
input bool          InpPush       = false;             // Push notification

input group "DISPLAY"
input ENUM_PRG_CORNER InpCorner   = PRG_LEFT;          // Panel position
input int           InpOffsetX    = 10;                // Panel margin from the side, px
input int           InpOffsetY    = 26;                // Panel margin from the top, px
input int           InpFontSize   = 9;                 // Panel font size
input bool          InpLight      = false;             // Light colours (for white charts)

input group "SERVER CLOCK"
input ENUM_PRG_CLOCK InpClock     = PRG_CLOCK_AUTO;    // Broker server clock
input int           InpFixedUTC   = 0;                 // Broker offset from UTC, hours (Fixed only)

//--- alert state for the current day (daily) and ever (max)
datetime g_warned_day=0,g_breached_day=0;
bool     g_warned_max=false,g_breached_max=false;
double   g_last_bal=0;
int      g_last_pos=-1;
int      g_panel_h=200;

void Notify(const string msg)
  {
   string m="Prop Rules Monitor: "+msg;
   if(InpPopup && !MQLInfoInteger(MQL_TESTER))
      Alert(m);
   else
      Print(m);
   if(InpPush && !MQLInfoInteger(MQL_TESTER))
      SendNotification(m);
  }

void CheckAlerts(void)
  {
   if(g_rules.daily_pct>0)
     {
      if(PrgDailyBreached() && g_breached_day!=g_st.day_start)
        {
         g_breached_day=g_st.day_start;
         g_warned_day=g_st.day_start;
         Notify(StringFormat("DAILY LIMIT BREACHED - equity %s at or below the floor %s",Money(g_st.equity),Money(g_st.daily_floor)));
        }
      else
         if(g_st.daily_used_pct>=InpWarnAt && g_warned_day!=g_st.day_start)
           {
            g_warned_day=g_st.day_start;
            Notify(StringFormat("%.0f%% of today's loss limit used - %s left",g_st.daily_used_pct,Money(PrgDailyRoom())));
           }
     }
   if(g_rules.max_pct>0)
     {
      if(PrgMaxBreached() && !g_breached_max)
        {
         g_breached_max=true;
         Notify(StringFormat("MAX LOSS BREACHED - equity %s at or below the floor %s",Money(g_st.equity),Money(g_st.max_floor)));
        }
      else
         if(g_st.max_used_pct>=InpWarnAt && !g_warned_max)
           {
            g_warned_max=true;
            Notify(StringFormat("%.0f%% of the max loss used - %s left",g_st.max_used_pct,Money(PrgMaxRoom())));
           }
      if(g_st.max_used_pct<InpWarnAt*0.9)          // re-arm after a clear recovery
         g_warned_max=g_breached_max=false;
     }
  }

void Draw(void)
  {
   string status="OK - within the limits";
   color  clr=UiPos();
   if(PrgMaxBreached())
     {
      status="MAX LOSS BREACHED";
      clr=UiNeg();
     }
   else
      if(PrgDailyBreached())
        {
         status="DAILY LIMIT BREACHED";
         clr=UiNeg();
        }
      else
         if(g_st.daily_used_pct>=InpWarnAt || g_st.max_used_pct>=InpWarnAt)
           {
            status="WARNING - near a limit";
            clr=UiWarn();
           }
   g_cursor=0;
   DrawBack(g_panel_h);
   int y=DrawBody("Prop Rules Monitor","MONITOR",status,clr);
   y=Row("clock",y,"Server clock",PrgClockName(),UiDim());
   if(y!=g_panel_h)
     {
      g_panel_h=y;
      g_cursor=0;
      DrawBack(g_panel_h);
     }
   if(g_panel_dirty)
     {
      ChartRedraw();
      g_panel_dirty=false;
     }
  }

void Refresh(void)
  {
   double bal=AccountInfoDouble(ACCOUNT_BALANCE);
   int pos=PositionsTotal();
   if(bal!=g_last_bal || pos!=g_last_pos)          // a deal happened: closed P&L and trading days change
     {
      g_last_bal=bal;
      g_last_pos=pos;
      PrgScanHistory();
     }
   PrgUpdate();
   CheckAlerts();
   Draw();
  }

int OnInit(void)
  {
   g_rules.name="Custom";
   g_rules.daily_pct=MathMax(0,InpDailyPct);
   g_rules.daily_of=InpDailyOf;
   g_rules.daily_ref=InpDailyRef;
   g_rules.reset_zone=InpResetZone;
   g_rules.reset_hour=MathMax(0,MathMin(23,InpResetHour));
   g_rules.max_pct=MathMax(0,InpMaxPct);
   g_rules.max_mode=InpMaxMode;
   g_rules.max_stop_at_initial=InpMaxStop;
   g_rules.smart_gain_pct=MathMax(0,InpSmartGain);
   g_rules.smart_after_pct=MathMax(0,InpSmartAfter);
   g_rules.target_pct=MathMax(0,InpTargetPct);
   g_rules.min_days=MathMax(0,InpMinDays);
   g_initial_input=MathMax(0,InpAccount);
   g_warn_at=MathMax(1,MathMin(99,InpWarnAt));
   g_ui_corner=InpCorner;
   g_ui_x=InpOffsetX;
   g_ui_y=InpOffsetY;
   g_ui_font=MathMax(7,MathMin(14,InpFontSize));
   g_ui_light=InpLight;
   PrgResolveClock(InpClock,InpFixedUTC);
   PrgInit();
   g_last_bal=AccountInfoDouble(ACCOUNT_BALANCE);
   g_last_pos=PositionsTotal();
   EventSetTimer(1);
   Refresh();
   return(INIT_SUCCEEDED);
  }

void OnDeinit(const int reason)
  {
   EventKillTimer();
   PanelDelete();
   ChartRedraw();
  }

void OnTimer(void)
  {
   Refresh();
  }

int OnCalculate(const int rates_total,const int prev_calculated,const int begin,const double &price[])
  {
//--- in the tester the timer runs too, but the visual tester repaints faster from ticks
   if(MQLInfoInteger(MQL_TESTER))
      Refresh();
   return(rates_total);
  }
//+------------------------------------------------------------------+
