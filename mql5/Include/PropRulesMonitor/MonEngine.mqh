//+------------------------------------------------------------------+
//|                                                    MonEngine.mqh |
//|                                      Copyright 2026, Allan Niñal |
//|                                  https://www.allanninal.dev/mql5 |
//+------------------------------------------------------------------+
//| Rule engine of Prop Rules Monitor. It only measures: day start,  |
//| daily and overall loss floors, trading days. It never trades.    |
//|                                                                  |
//| Daily floor  = day-start reference - daily limit                 |
//|   reference: balance, equity or the higher of the two at the     |
//|   reset instant (a time of day in a chosen time zone);           |
//|   limit: % of the initial balance or of that reference.          |
//| Overall floor = initial - max%  (static), or the peak (equity,   |
//|   balance, or end-of-day balance) - max% of the initial, which   |
//|   can stop rising once it reaches the initial balance.           |
//| Breach = equity at or below a floor (open trades count).         |
//| Times: deals and resets are compared in broker server time; the  |
//| reset zone is converted with built-in EU/US daylight-saving      |
//| rules. Nothing here uses the network.                            |
//+------------------------------------------------------------------+
// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0 (see LICENSE)
#ifndef PRG_ENGINE_MQH
#define PRG_ENGINE_MQH

//--- MT5 shows each enum choice by the comment on its own line, so every member needs one
enum ENUM_PRG_REF
  {
   PRG_REF_BALANCE=0,   // Balance at the reset
   PRG_REF_EQUITY=1,    // Equity at the reset
   PRG_REF_HIGHER=2     // Higher of balance and equity at the reset
  };
enum ENUM_PRG_OF
  {
   PRG_OF_INITIAL=0,    // % of the initial balance (account size)
   PRG_OF_DAYSTART=1    // % of the day-start reference
  };
enum ENUM_PRG_ZONE
  {
   PRG_ZONE_BROKER=0,   // Broker server time
   PRG_ZONE_PRAGUE=1,   // Central Europe (Prague, CET/CEST)
   PRG_ZONE_UTC=2,      // UTC
   PRG_ZONE_NEWYORK=3,  // New York (EST/EDT)
   PRG_ZONE_LONDON=4,   // London (GMT/BST)
   PRG_ZONE_UTC3=5      // UTC+3 all year
  };
enum ENUM_PRG_MAX
  {
   PRG_MAX_STATIC=0,    // Static: initial balance - max %
   PRG_MAX_TRAIL_EQ=1,  // Trailing from the highest equity
   PRG_MAX_TRAIL_BAL=2, // Trailing from the highest closed balance
   PRG_MAX_EOD=3,       // Trailing from the highest end-of-day balance
   PRG_MAX_SMART=4      // Two-stage: max % until a gain, then a smaller fixed %
  };
enum ENUM_PRG_CLOCK
  {
   PRG_CLOCK_AUTO=0,    // Auto: detect from the live server time
   PRG_CLOCK_NY=1,      // New York close: UTC+2/+3 with US daylight saving
   PRG_CLOCK_EET=2,     // UTC+2/+3 with European daylight saving
   PRG_CLOCK_FIXED=3    // Fixed offset from UTC, no daylight saving
  };

//--- one set of rules (the user's own)
struct MonRules
  {
   string            name;
   double            daily_pct;        // 0 = no daily limit
   ENUM_PRG_REF      daily_ref;
   ENUM_PRG_OF       daily_of;
   ENUM_PRG_ZONE     reset_zone;
   int               reset_hour;       // hour of the reset in that zone (0-23)
   double            max_pct;          // 0 = no overall limit
   ENUM_PRG_MAX      max_mode;
   bool              max_stop_at_initial; // a trailing floor stops rising at the initial balance
   double            smart_gain_pct;   // PRG_MAX_SMART: closed-balance gain that switches the floor ...
   double            smart_after_pct;  // ... to account size - this %
   double            target_pct;       // profit target, 0 = none
   int               min_days;         // minimum trading days, 0 = none
  };

//--- what the engine measured, for the panel
struct PrgState
  {
   double            initial;          // account size the % limits use
   bool              initial_auto;     // taken from the first deposit
   datetime          day_start;        // current reset instant, server time
   datetime          next_reset;
   double            ref_balance;      // balance at the reset
   double            ref_equity;       // equity at the reset (= balance when not measured)
   bool              ref_measured;     // true when the program was running at the reset
   double            daily_floor;      // equity at or below this breaks the daily limit (-DBL_MAX = off)
   double            daily_limit;      // money
   double            max_floor;        // (-DBL_MAX = off)
   double            peak_equity;
   double            peak_balance;
   double            peak_eod;
   double            balance,equity;
   double            today_closed;     // closed P&L since the reset
   int               trading_days;     // days with at least one new trade
   double            daily_used_pct;   // 0..100+ of the daily limit
   double            max_used_pct;
  };

MonRules g_rules;
PrgState g_st;

//--- clock of the broker server, resolved once
ENUM_PRG_CLOCK g_prg_clock=PRG_CLOCK_NY;
int            g_prg_fixed=0;          // seconds, PRG_CLOCK_FIXED

//+------------------------------------------------------------------+
//| Time zones                                                       |
//+------------------------------------------------------------------+
//--- Sunday on or after `day` of `month` in year `y`, at `hour` UTC
datetime PrgSundayFrom(const int y,const int month,const int day,const int hour)
  {
   MqlDateTime t;
   ZeroMemory(t);
   t.year=y;
   t.mon=month;
   t.day=day;
   datetime d=StructToTime(t);
   TimeToStruct(d,t);
   return(d+(datetime)(((7-t.day_of_week)%7)*86400+hour*3600));
  }

//--- US daylight saving: second Sunday of March 07:00 UTC to first Sunday of November 06:00 UTC
bool PrgUsDst(const datetime utc)
  {
   MqlDateTime t;
   TimeToStruct(utc,t);
   return(utc>=PrgSundayFrom(t.year,3,8,7) && utc<PrgSundayFrom(t.year,11,1,6));
  }

//--- EU summer time: last Sunday of March to last Sunday of October, 01:00 UTC
bool PrgEuDst(const datetime utc)
  {
   MqlDateTime t;
   TimeToStruct(utc,t);
   return(utc>=PrgSundayFrom(t.year,3,25,1) && utc<PrgSundayFrom(t.year,10,25,1));
  }

//--- offset of a named zone from UTC at UTC time `utc`, seconds
int PrgZoneOffset(const ENUM_PRG_ZONE zone,const datetime utc)
  {
   switch(zone)
     {
      case PRG_ZONE_PRAGUE:  return(PrgEuDst(utc) ? 2*3600 : 3600);
      case PRG_ZONE_LONDON:  return(PrgEuDst(utc) ? 3600 : 0);
      case PRG_ZONE_NEWYORK: return(PrgUsDst(utc) ? -4*3600 : -5*3600);
      case PRG_ZONE_UTC3:    return(3*3600);
      default:               return(0);
     }
  }

//--- the broker's offset from UTC at server time `srv`
int PrgBrokerOffset(const datetime srv)
  {
   if(g_prg_clock==PRG_CLOCK_FIXED)
      return(g_prg_fixed);
   if(g_prg_clock==PRG_CLOCK_EET)
      return(PrgEuDst(srv-2*3600) ? 3*3600 : 2*3600);
   return(PrgUsDst(srv-2*3600) ? 3*3600 : 2*3600);
  }

//--- decide the server clock: the input, or the live server time against UTC (the tester can't tell)
void PrgResolveClock(const ENUM_PRG_CLOCK input_clock,const int fixed_hours)
  {
   g_prg_clock=input_clock;
   g_prg_fixed=fixed_hours*3600;
   if(input_clock!=PRG_CLOCK_AUTO)
      return;
   g_prg_clock=PRG_CLOCK_NY;
   if(MQLInfoInteger(MQL_TESTER))
      return;
   datetime gmt=TimeGMT();
   long off=(long)TimeTradeServer()-(long)gmt;
   off=(long)MathRound(off/1800.0)*1800;
   if(MathAbs(off)>14*3600)                    // a frozen weekend server time: keep New York close
      return;
   int ny=PrgUsDst(gmt) ? 3*3600 : 2*3600;
   int eu=PrgEuDst(gmt) ? 3*3600 : 2*3600;
   if(off==ny)
      return;
   if(off==eu)
     {
      g_prg_clock=PRG_CLOCK_EET;
      return;
     }
   g_prg_clock=PRG_CLOCK_FIXED;
   g_prg_fixed=(int)off;
  }

string PrgClockName(void)
  {
   switch(g_prg_clock)
     {
      case PRG_CLOCK_EET:   return("UTC+2/+3 EU");
      case PRG_CLOCK_FIXED: return(StringFormat("UTC%+.1f",g_prg_fixed/3600.0));
      default:              return("NY close");
     }
  }

//--- floor `t` to the last instant whose time of day is `hour`:00 (all in one clock)
datetime PrgFloorToHour(const datetime t,const int hour)
  {
   long k=(long)t-hour*3600;
   long m=k%86400;
   if(m<0)
      m+=86400;
   return((datetime)((long)t-m));
  }

//--- the reset instant (server time) of the trading day that contains server time `srv`
datetime PrgDayStart(const datetime srv)
  {
   if(g_rules.reset_zone==PRG_ZONE_BROKER)
      return(PrgFloorToHour(srv,g_rules.reset_hour));
   datetime utc=srv-PrgBrokerOffset(srv);
   datetime loc=utc+PrgZoneOffset(g_rules.reset_zone,utc);
   datetime rl=PrgFloorToHour(loc,g_rules.reset_hour);           // reset, zone local time
   datetime ru=rl-PrgZoneOffset(g_rules.reset_zone,rl-PrgZoneOffset(g_rules.reset_zone,utc));
   return(ru+PrgBrokerOffset(ru+2*3600));
  }

string PrgZoneName(const ENUM_PRG_ZONE z)
  {
   switch(z)
     {
      case PRG_ZONE_PRAGUE:  return("Prague");
      case PRG_ZONE_UTC:     return("UTC");
      case PRG_ZONE_NEWYORK: return("New York");
      case PRG_ZONE_LONDON:  return("London");
      case PRG_ZONE_UTC3:    return("UTC+3");
      default:               return("server");
     }
  }

//--- current server time: TimeTradeServer() live, TimeCurrent() in the tester
datetime PrgNow(void)
  {
   return(MQLInfoInteger(MQL_TESTER) ? TimeCurrent() : TimeTradeServer());
  }

//+------------------------------------------------------------------+
//| Persistence: terminal global variables keyed by the login, so a  |
//| restart, re-attach or timeframe change keeps peaks and the day   |
//| start: PRG.<login>.MON.<field>.                                  |
//+------------------------------------------------------------------+
string PrgKey(const string field)
  {
   return("PRG."+IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN))+".MON."+field);
  }

double PrgGet(const string field,const double def)
  {
   string k=PrgKey(field);
   return(GlobalVariableCheck(k) ? GlobalVariableGet(k) : def);
  }

void PrgSet(const string field,const double v)
  {
   if(MQLInfoInteger(MQL_TESTER) && MQLInfoInteger(MQL_OPTIMIZATION))
      return;
   GlobalVariableSet(PrgKey(field),v);
  }

//+------------------------------------------------------------------+
//| History scan: initial deposit, closed P&L per trading day, peak  |
//| balance, peak end-of-day balance, trading days. Called at start  |
//| and after every new deal; prop accounts have short histories.    |
//+------------------------------------------------------------------+
double   g_day_pnl[];                      // closed P&L per trading day ...
datetime g_day_key[];                      // ... keyed by its reset instant
bool     g_day_traded[];                   // a new position was opened that day
double   g_initial_input=0;                // 0 = first deposit

int PrgDaySlot(const datetime key)
  {
   int n=ArraySize(g_day_key);
   if(n>0 && g_day_key[n-1]==key)
      return(n-1);
   for(int i=n-1; i>=0; i--)
      if(g_day_key[i]==key)
         return(i);
   ArrayResize(g_day_key,n+1,64);
   ArrayResize(g_day_pnl,n+1,64);
   ArrayResize(g_day_traded,n+1,64);
   g_day_key[n]=key;
   g_day_pnl[n]=0;
   g_day_traded[n]=false;
   return(n);
  }

//--- running totals of the scan, so each call reads only the deals added since the last one
double   g_scan_run=0,g_scan_peak=0,g_scan_eod=0,g_scan_day_end=0,g_scan_first=0;
datetime g_scan_day=0,g_scan_time=0;
ulong    g_scan_ticket=0;

void PrgScanReset(void)
  {
   ArrayResize(g_day_key,0);
   ArrayResize(g_day_pnl,0);
   ArrayResize(g_day_traded,0);
   g_scan_run=g_scan_peak=g_scan_eod=g_scan_day_end=g_scan_first=0;
   g_scan_day=g_scan_time=0;
   g_scan_ticket=0;
  }

void PrgScanHistory(void)
  {
   datetime now=PrgNow();
   if(HistorySelect(g_scan_time,now+86400))
     {
      int n=HistoryDealsTotal();
      for(int i=0; i<n; i++)
        {
         ulong d=HistoryDealGetTicket(i);
         if(d==0 || d<=g_scan_ticket)                 // read already (tickets only grow)
            continue;
         g_scan_ticket=d;
         long     type=HistoryDealGetInteger(d,DEAL_TYPE);
         datetime t=(datetime)HistoryDealGetInteger(d,DEAL_TIME);
         double   v=HistoryDealGetDouble(d,DEAL_PROFIT)+HistoryDealGetDouble(d,DEAL_COMMISSION)+
                    HistoryDealGetDouble(d,DEAL_SWAP)+HistoryDealGetDouble(d,DEAL_FEE);
         g_scan_time=MathMax(g_scan_time,t);
         datetime key=PrgDayStart(t);
         if(g_scan_day!=0 && key!=g_scan_day)          // a day ended: its closing balance
            g_scan_eod=MathMax(g_scan_eod,g_scan_day_end);
         g_scan_day=key;
         g_scan_run+=v;
         g_scan_day_end=g_scan_run;
         if(type==DEAL_TYPE_BALANCE)
           {
            if(g_scan_first==0 && v>0)
               g_scan_first=v;
            g_scan_peak=MathMax(g_scan_peak,g_scan_run);
            g_scan_eod=MathMax(g_scan_eod,g_scan_run);
            continue;
           }
         if(type!=DEAL_TYPE_BUY && type!=DEAL_TYPE_SELL)
            continue;
         int s=PrgDaySlot(key);
         g_day_pnl[s]+=v;
         if(HistoryDealGetInteger(d,DEAL_ENTRY)==DEAL_ENTRY_IN)
            g_day_traded[s]=true;
         g_scan_peak=MathMax(g_scan_peak,g_scan_run);
        }
     }
   double bal=AccountInfoDouble(ACCOUNT_BALANCE);
   double first_dep=g_scan_first>0 ? g_scan_first : bal-g_scan_run;   // tester or no deposit in history
   g_st.initial_auto=(g_initial_input<=0);
   g_st.initial=g_initial_input>0 ? g_initial_input : (first_dep>0 ? first_dep : bal);
   g_st.peak_balance=MathMax(MathMax(g_scan_peak,g_st.initial),bal);
//--- end-of-day peak: days that closed before today's reset, plus the stored live value
   datetime today=PrgDayStart(now);
   double peak_eod=g_scan_eod;
   if(g_scan_day!=0 && g_scan_day<today)
      peak_eod=MathMax(peak_eod,g_scan_day_end);
   g_st.peak_eod=MathMax(MathMax(peak_eod,g_st.initial),MathMax(g_st.peak_eod,PrgGet("peak_eod",0)));
   PrgTotals(today);
  }

//--- trading-day totals from the per-day table
void PrgTotals(const datetime today)
  {
   g_st.trading_days=0;
   g_st.today_closed=0;
   for(int i=0; i<ArraySize(g_day_key); i++)
     {
      if(g_day_traded[i])
         g_st.trading_days++;
      if(g_day_key[i]==today)
         g_st.today_closed=g_day_pnl[i];
     }
  }

//+------------------------------------------------------------------+
//| Day start: measured when the program runs through the reset,     |
//| otherwise rebuilt as the balance minus every deal since then.    |
//| Equity at a reset the program missed cannot be known: it then    |
//| equals the rebuilt balance and the panel says "rebuilt".         |
//+------------------------------------------------------------------+
//--- money moved in the history at or after a time (every deal: closed P&L, costs and balance operations)
double PrgMovedSince(const datetime start)
  {
   double since=0;
   if(HistorySelect(start,PrgNow()+86400))
      for(int i=HistoryDealsTotal()-1; i>=0; i--)
        {
         ulong d=HistoryDealGetTicket(i);
         if(d==0 || (datetime)HistoryDealGetInteger(d,DEAL_TIME)<start)
            continue;
         since+=HistoryDealGetDouble(d,DEAL_PROFIT)+HistoryDealGetDouble(d,DEAL_COMMISSION)+
                HistoryDealGetDouble(d,DEAL_SWAP)+HistoryDealGetDouble(d,DEAL_FEE);
        }
   return(since);
  }

void PrgRebuildDayStart(const datetime start)
  {
   g_st.ref_balance=AccountInfoDouble(ACCOUNT_BALANCE)-PrgMovedSince(start);
   g_st.ref_equity=g_st.ref_balance;
   g_st.ref_measured=false;
  }

//--- start (or restart) the engine
void PrgInit(void)
  {
   ZeroMemory(g_st);
   g_st.day_start=0;
   PrgScanReset();
   PrgScanHistory();
   g_st.peak_equity=MathMax(PrgGet("peak_eq",0),MathMax(g_st.peak_balance,AccountInfoDouble(ACCOUNT_EQUITY)));
   datetime now=PrgNow();
   datetime start=PrgDayStart(now);
//--- a day start stored by a program that was running at the reset is kept
   if((datetime)PrgGet("day",0)==start)
     {
      g_st.ref_balance=PrgGet("day_bal",0);
      g_st.ref_equity=PrgGet("day_eq",0);
      g_st.ref_measured=PrgGet("day_meas",0)>0;
     }
   else
     {
      PrgRebuildDayStart(start);
      PrgSet("day",(double)start);
      PrgSet("day_bal",g_st.ref_balance);
      PrgSet("day_eq",g_st.ref_equity);
      PrgSet("day_meas",0);
     }
   g_st.day_start=start;
   g_st.next_reset=PrgDayStart(start+26*3600);
   if(g_st.next_reset<=start)
      g_st.next_reset=start+86400;
  }

//+------------------------------------------------------------------+
//| Per tick / timer update. Returns true when a new day started.    |
//+------------------------------------------------------------------+
bool PrgUpdate(void)
  {
   bool new_day=false;
   datetime now=PrgNow();
   g_st.balance=AccountInfoDouble(ACCOUNT_BALANCE);
   g_st.equity=AccountInfoDouble(ACCOUNT_EQUITY);
   if(now>=g_st.next_reset)
     {
      //--- running through the reset: today's reference is measured, yesterday's close is an end-of-day value;
      //--- the first tick of the day can come late (a gap, the terminal off) with stops already filled after the
      //--- reset: those belong to the new day, so they are taken out of both
      g_st.day_start=PrgDayStart(now);
      g_st.next_reset=PrgDayStart(g_st.day_start+26*3600);
      if(g_st.next_reset<=g_st.day_start)
         g_st.next_reset=g_st.day_start+86400;
      double since=PrgMovedSince(g_st.day_start);
      g_st.peak_eod=MathMax(g_st.peak_eod,g_st.balance-since);
      PrgSet("peak_eod",g_st.peak_eod);
      g_st.ref_balance=g_st.balance-since;
      g_st.ref_equity=g_st.equity-since;
      g_st.ref_measured=true;
      g_st.today_closed=0;
      PrgSet("day",(double)g_st.day_start);
      PrgSet("day_bal",g_st.ref_balance);
      PrgSet("day_eq",g_st.ref_equity);
      PrgSet("day_meas",1);
      PrgTotals(g_st.day_start);
      new_day=true;
     }
   if(g_st.equity>g_st.peak_equity)
     {
      g_st.peak_equity=g_st.equity;
      PrgSet("peak_eq",g_st.peak_equity);
     }
   g_st.peak_balance=MathMax(g_st.peak_balance,g_st.balance);
//--- daily floor
   g_st.daily_floor=-DBL_MAX;
   g_st.daily_limit=0;
   if(g_rules.daily_pct>0)
     {
      double ref=g_st.ref_balance;
      if(g_rules.daily_ref==PRG_REF_EQUITY)
         ref=g_st.ref_equity;
      else
         if(g_rules.daily_ref==PRG_REF_HIGHER)
            ref=MathMax(g_st.ref_balance,g_st.ref_equity);
      g_st.daily_limit=g_rules.daily_pct/100.0*(g_rules.daily_of==PRG_OF_INITIAL ? g_st.initial : ref);
      g_st.daily_floor=ref-g_st.daily_limit;
      g_st.daily_used_pct=g_st.daily_limit>0 ? 100.0*(ref-g_st.equity)/g_st.daily_limit : 0;
     }
//--- overall floor
   g_st.max_floor=-DBL_MAX;
   if(g_rules.max_pct>0)
     {
      double amount=g_rules.max_pct/100.0*g_st.initial;
      double peak=g_st.initial;
      switch(g_rules.max_mode)
        {
         case PRG_MAX_TRAIL_EQ:  peak=g_st.peak_equity;  break;
         case PRG_MAX_TRAIL_BAL: peak=g_st.peak_balance; break;
         case PRG_MAX_EOD:       peak=g_st.peak_eod;     break;
         default:                break;
        }
      g_st.max_floor=peak-amount;
      if(g_rules.max_mode==PRG_MAX_SMART && g_rules.smart_gain_pct>0 &&
         g_st.peak_balance>=g_st.initial*(1.0+g_rules.smart_gain_pct/100.0))
        {
         amount=g_rules.smart_after_pct/100.0*g_st.initial;
         g_st.max_floor=g_st.initial-amount;
        }
      if(g_rules.max_mode!=PRG_MAX_STATIC && g_rules.max_mode!=PRG_MAX_SMART && g_rules.max_stop_at_initial)
         g_st.max_floor=MathMin(g_st.max_floor,g_st.initial);
      //--- share of the loss budget used: 0 with the full amount of room, 100 at the floor
      g_st.max_used_pct=amount>0 ? 100.0*(amount-(g_st.equity-g_st.max_floor))/amount : 0;
     }
   return(new_day);
  }

//--- equity at or below the daily floor
bool PrgDailyBreached(void) { return(g_st.daily_floor>-DBL_MAX && g_st.equity<=g_st.daily_floor); }
bool PrgMaxBreached(void)   { return(g_st.max_floor>-DBL_MAX && g_st.equity<=g_st.max_floor); }

//--- money left before a floor (DBL_MAX when the rule is off)
double PrgDailyRoom(void) { return(g_st.daily_floor>-DBL_MAX ? g_st.equity-g_st.daily_floor : DBL_MAX); }
double PrgMaxRoom(void)   { return(g_st.max_floor>-DBL_MAX ? g_st.equity-g_st.max_floor : DBL_MAX); }

#endif
//+------------------------------------------------------------------+
