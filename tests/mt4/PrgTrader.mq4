//+------------------------------------------------------------------+
//|                                                    PrgTrader.mq4 |
//|                                      Copyright 2026, Allan Niñal |
//|                                  https://www.allanninal.dev/mql5 |
//+------------------------------------------------------------------+
//| Test EA (not shipped) for the MT4 rule engine (MonEngine.mqh)   |
//| of Prop Rules Monitor MT4, run in the MT4 Strategy Tester (tester|
//| trades only). It trades a seeded random mix on new bars (market  |
//| orders, stop loss / take profit, partial and full closes) and    |
//| runs the engine as the indicator does (scan on a balance or      |
//| position change, update on every tick). Every InpSnapBars bars   |
//| it writes the engine's history results to                        |
//| <tag>_<SYM>_<TF>_state.csv; at the end every order to            |
//| <tag>_<SYM>_<TF>_orders.csv. tests/mt4/check_mt4.py rebuilds the |
//| results from the orders on its own. The indicator is not run    |
//| beside it: both would share the stored values (PRG.*.MON.*).    |
//+------------------------------------------------------------------+
// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0 (see LICENSE)
#property strict
#include <PropRulesMonitor\MonEngine.mqh>

input string        InpTag       = "prg";
input int           InpSeed      = 1;
input int           InpSnapBars  = 7;               // bars between snapshots (7 = every hour of the day in turn)
input int           InpMaxOpen   = 6;
input ENUM_PRG_ZONE InpResetZone = PRG_ZONE_PRAGUE;
input int           InpResetHour = 0;
input ENUM_PRG_CLOCK InpClock    = PRG_CLOCK_AUTO;   // AUTO = New York close in the tester

string   g_base;
int      g_f=INVALID_HANDLE,g_bars=0,g_ops=0,g_fail=0,g_snaps=0;
datetime g_last_bar=0;
double   g_last_bal=0;
int      g_last_pos=-1;
bool     g_done=false;
int      LOTS[4]={1,1,2,4};                          // in minimum lots

int Rnd(const int n) { return(MathRand()%n); }

int MarketOrders(void)
  {
   int n=0;
   for(int i=OrdersTotal()-1; i>=0; i--)
      if(OrderSelect(i,SELECT_BY_POS,MODE_TRADES) && OrderType()<=OP_SELL)
         n++;
   return(n);
  }

int OnInit()
  {
   MathSrand(InpSeed);
   GlobalVariablesDeleteAll(PrgKey(""));             // the MT4 tester keeps global variables from the previous run
   g_rules.name="Test";
   g_rules.daily_pct=5;
   g_rules.daily_of=PRG_OF_INITIAL;
   g_rules.daily_ref=PRG_REF_BALANCE;
   g_rules.reset_zone=InpResetZone;
   g_rules.reset_hour=InpResetHour;
   g_rules.max_pct=10;
   g_rules.max_mode=PRG_MAX_EOD;
   PrgResolveClock(InpClock,0);
   PrgInit();
   g_base=StringFormat("%s_%s_%s",InpTag,_Symbol,TfName());
   g_f=FileOpen(g_base+"_state.csv",FILE_WRITE|FILE_TXT|FILE_ANSI);
   FileWriteString(g_f,"now,balance,day_start,next_reset,initial,peak_balance,peak_eod,"
                   "trading_days,today_closed,rebuilt_ref,final,days\n");
   return(INIT_SUCCEEDED);
  }

string TfName(void)
  {
   switch(_Period)
     {
      case PERIOD_M15: return("M15");
      case PERIOD_H1:  return("H1");
      case PERIOD_H4:  return("H4");
     }
   return(IntegerToString(_Period));
  }

void Trade(void)
  {
   int r=Rnd(100);
   RefreshRates();
   double mn=MarketInfo(_Symbol,MODE_MINLOT),st=MarketInfo(_Symbol,MODE_LOTSTEP);
   if(r<30 && MarketOrders()<InpMaxOpen)
     {
      int type=Rnd(2);
      double lots=mn*LOTS[Rnd(4)],price=(type==OP_BUY ? Ask : Bid),sl=0,tp=0;
      if(Rnd(10)<5)
        {
         double d=(100+Rnd(400))*_Point;
         sl=NormalizeDouble(type==OP_BUY ? price-d : price+d,_Digits);
         tp=NormalizeDouble(type==OP_BUY ? price+d : price-d,_Digits);
        }
      g_ops++;
      if(OrderSend(_Symbol,type,NormalizeDouble(lots,2),price,50,sl,tp,"prg test",Rnd(3),0,clrNONE)<0)
         g_fail++;
      return;
     }
   int n=OrdersTotal();
   if(n==0 || !OrderSelect(Rnd(n),SELECT_BY_POS,MODE_TRADES) || OrderType()>OP_SELL)
      return;
   int    tk=OrderTicket();
   double lots=OrderLots(),price=(OrderType()==OP_BUY ? Bid : Ask);
   double half=MathFloor(lots/2.0/st+1e-9)*st;
   if(r<50 && half>=mn-1e-9)
     {
      g_ops++;
      if(!OrderClose(tk,NormalizeDouble(half,2),price,50,clrNONE))
         g_fail++;
     }
   else
      if(r<75)
        {
         g_ops++;
         if(!OrderClose(tk,lots,price,50,clrNONE))
            g_fail++;
        }
  }

void Snapshot(const bool last=false)
  {
//--- the rebuilt day start (as PrgInit does after a restart), without touching the engine's own reference
   PrgState keep=g_st;
   PrgRebuildDayStart(PrgDayStart(PrgNow()));
   double rebuilt=g_st.ref_balance;
   g_st=keep;
   string days="";
   for(int i=0; i<ArraySize(g_day_key); i++)
      days+=StringFormat("%s%I64d:%.2f:%d",i ? ";" : "",(long)g_day_key[i],g_day_pnl[i],g_day_traded[i] ? 1 : 0);
   FileWriteString(g_f,StringFormat("%I64d,%.2f,%I64d,%I64d,%.2f,%.2f,%.2f,%d,%.2f,%.2f,%d,",
                   (long)PrgNow(),AccountBalance(),(long)g_st.day_start,(long)g_st.next_reset,g_st.initial,g_st.peak_balance,
                   g_st.peak_eod,g_st.trading_days,g_st.today_closed,rebuilt,last ? 1 : 0));
   FileWriteString(g_f,days+"\n");                  // apart: MQL4's StringFormat stops at about 4 KB
   g_snaps++;
  }

void OnTick()
  {
//--- the engine as the indicator runs it
   double bal=AccountBalance();
   int pos=MarketOrders();
   if(bal!=g_last_bal || pos!=g_last_pos)
     {
      g_last_bal=bal;
      g_last_pos=pos;
      PrgScanHistory();
     }
   PrgUpdate();
   datetime bt=iTime(NULL,0,0);
   if(bt==g_last_bar)
      return;
   g_last_bar=bt;
   g_bars++;
   if(g_bars%InpSnapBars==0)
      Snapshot();
   Trade();
  }

void Finish(void)
  {
   if(g_done)
      return;
   g_done=true;
   PrgScanHistory();
   PrgUpdate();
   Snapshot(true);                                  // after the tester closed what was open
   FileClose(g_f);
   int f=FileOpen(g_base+"_orders.csv",FILE_WRITE|FILE_TXT|FILE_ANSI);
   FileWriteString(f,"pool,ticket,type,open_time,close_time,lots,profit,swap,commission,comment\n");
   for(int pass=0; pass<2; pass++)
      for(int i=0; i<(pass==0 ? OrdersHistoryTotal() : OrdersTotal()); i++)
         if(OrderSelect(i,SELECT_BY_POS,pass==0 ? MODE_HISTORY : MODE_TRADES))
           {
            string c=OrderComment();
            StringReplace(c,",",";");
            FileWriteString(f,StringFormat("%s,%d,%d,%I64d,%I64d,%.2f,%.8f,%.8f,%.8f,%s\n",pass==0 ? "history" : "open",OrderTicket(),
                            OrderType(),(long)OrderOpenTime(),pass==0 ? (long)OrderCloseTime() : 0,OrderLots(),OrderProfit(),
                            OrderSwap(),OrderCommission(),c));
           }
   FileClose(f);
   PrintFormat("Dump4 %s.csv: %d bars, %d trade operations (%d refused), %d snapshots, clock %s, reset %s %02d:00, history %d orders",
               g_base,g_bars,g_ops,g_fail,g_snaps,PrgClockName(),PrgZoneName(g_rules.reset_zone),g_rules.reset_hour,OrdersHistoryTotal());
  }

double OnTester()
  {
   Finish();
   return(0.0);
  }

void OnDeinit(const int reason)
  {
   Finish();
  }
//+------------------------------------------------------------------+
