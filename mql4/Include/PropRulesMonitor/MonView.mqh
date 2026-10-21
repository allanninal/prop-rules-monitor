//+------------------------------------------------------------------+
//|                                                      MonView.mqh |
//|                                      Copyright 2026, Allan Niñal |
//|                                  https://www.allanninal.dev/mql5 |
//+------------------------------------------------------------------+
//| The panel body: today's limit, the overall limit, the profit     |
//| target and the account. `status` / `status_clr` come from the    |
//| indicator, which only reports.                                   |
//+------------------------------------------------------------------+
// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0 (see LICENSE)
#ifndef PRG_VIEW_MQH
#define PRG_VIEW_MQH

#include "MonEngine.mqh"
#include "MonPanel.mqh"

double g_warn_at=80;                       // % of a limit used that turns the bar amber and alerts once

string RefName(void)
  {
   switch(g_rules.daily_ref)
     {
      case PRG_REF_EQUITY: return("equity");
      case PRG_REF_HIGHER: return("higher");
      default:             return("balance");
     }
  }

//--- "5%" or "2.5%"
string PctG(const double v)
  {
   return(MathAbs(v-MathRound(v))<1e-9 ? IntegerToString((int)MathRound(v))+"%" : DoubleToString(v,1)+"%");
  }

string MaxModeName(void)
  {
   switch(g_rules.max_mode)
     {
      case PRG_MAX_TRAIL_EQ:  return("trail equity");
      case PRG_MAX_TRAIL_BAL: return("trail balance");
      case PRG_MAX_EOD:       return("day-end trail");
      case PRG_MAX_SMART:     return("then "+PctG(g_rules.smart_after_pct)+" after +"+PctG(g_rules.smart_gain_pct));
      default:                return("static");
     }
  }

//--- the panel; `title`, `edition` (badge), `status`; returns the bottom y for the program to add rows
int DrawBody(const string title,const string edition,const string status,const color status_clr)
  {
   int y=0;
   Text("title",UI_PAD,5,title,UiText(),g_ui_font+1,"Segoe UI Semibold");
   Text("ed",UI_W-UI_PAD-7*StringLen(edition),7,edition,UiAccent(),g_ui_font-1);
   y=UI_HEAD;
   y=Row("rules",y,"Rules",g_rules.name,UiAccent());
   y=Row("status",y,"Status",status,status_clr);
   string cur=" "+AccountInfoString(ACCOUNT_CURRENCY);

//--- today
   if(g_rules.daily_pct>0)
     {
      y=Section("s_day",y,"DAILY LOSS LIMIT");
      y=Row("d_rule",y,"Rule",PctG(g_rules.daily_pct)+(g_rules.daily_of==PRG_OF_INITIAL ? " of size" : " of day start")+
            ", from "+RefName(),UiText());
      double ref=g_st.daily_floor+g_st.daily_limit;
      y=Row("d_ref",y,"Day start",Money(ref)+cur+(g_st.ref_measured ? "" : " rebuilt"),
            g_st.ref_measured ? UiText() : UiWarn());
      y=Row("d_floor",y,"Floor",Money(g_st.daily_floor)+cur,UiText());
      double room=PrgDailyRoom();
      y=Row("d_room",y,"Room left",Money(room)+cur,room<=0 ? UiNeg() : (g_st.daily_used_pct>=g_warn_at ? UiWarn() : UiPos()));
      y=Row("d_used",y,"Used",Pct(MathMax(0,g_st.daily_used_pct),0),g_st.daily_used_pct>=g_warn_at ? UiWarn() : UiText());
      y=Bar("d_bar",y,g_st.daily_used_pct,g_warn_at);
      datetime now=PrgNow();
      string at=g_rules.reset_zone==PRG_ZONE_BROKER ? StringFormat("%02d:00 server",g_rules.reset_hour) :
                StringFormat("%02d:00 %s",g_rules.reset_hour,PrgZoneName(g_rules.reset_zone));
      y=Row("d_reset",y,"Resets in",Clock((int)(g_st.next_reset-now))+"  ("+at+")",UiDim());
     }

//--- overall
   if(g_rules.max_pct>0)
     {
      y=Section("s_max",y,"MAX LOSS");
      y=Row("m_rule",y,"Rule",PctG(g_rules.max_pct)+" of size, "+MaxModeName()+
            (g_rules.max_stop_at_initial && g_rules.max_mode!=PRG_MAX_STATIC && g_rules.max_mode!=PRG_MAX_SMART ? ", locks" : ""),UiText());
      y=Row("m_floor",y,"Floor",Money(g_st.max_floor)+cur,UiText());
      double room=PrgMaxRoom();
      y=Row("m_room",y,"Room left",Money(room)+cur,room<=0 ? UiNeg() : (g_st.max_used_pct>=g_warn_at ? UiWarn() : UiPos()));
      y=Bar("m_bar",y,g_st.max_used_pct,g_warn_at);
     }

//--- account
   y=Section("s_acc",y,"ACCOUNT");
   y=Row("a_size",y,"Account size",Money(g_st.initial)+cur+(g_st.initial_auto ? " auto" : ""),UiText());
   y=Row("a_eq",y,"Equity",Money(g_st.equity)+cur,UiText());
   double pnl=g_st.equity-g_st.initial;
   if(g_rules.target_pct>0)
     {
      double target=g_rules.target_pct/100.0*g_st.initial;
      double done=target>0 ? 100.0*pnl/target : 0;
      y=Row("a_tgt",y,"Target",SMoney(pnl)+" of "+Money(target)+" "+Pct(MathMax(0,done),0),done>=100 ? UiPos() : Sign(pnl));
     }
   else
      y=Row("a_tgt",y,"Profit",SMoney(pnl)+cur,Sign(pnl));
   y=Row("a_today",y,"Today",SMoney(g_st.equity-g_st.ref_balance)+" (closed "+SMoney(g_st.today_closed)+")",
         Sign(g_st.equity-g_st.ref_balance));
   if(g_rules.min_days>0)
      y=Row("a_days",y,"Trading days",IntegerToString(g_st.trading_days)+" of "+IntegerToString(g_rules.min_days),
            g_st.trading_days>=g_rules.min_days ? UiPos() : UiText());
   else
      y=Row("a_days",y,"Trading days",IntegerToString(g_st.trading_days),UiText());
   return(y);
  }

//--- background sized to the last drawn content; call first in every redraw so it is created below the text
void DrawBack(const int height)
  {
   Box("bg",0,0,UI_W,height+UI_PAD,UiBack(),UiRule());
   Box("hd",0,0,UI_W,UI_HEAD-4,g_ui_light ? C'240,241,244' : C'32,35,40',UiRule());
  }

#endif
//+------------------------------------------------------------------+
