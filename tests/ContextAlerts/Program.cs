using CodexTokenOverlay;
var tracker = new ContextAlertTracker();
var time = DateTime.UtcNow;
var levels = new double[] {20,10,5};
int count=0;
void Check(string thread, long used, long window, double? expected, int? tick=null)
{
 var actual=tracker.Observe(thread,used,window,time.AddSeconds(tick ?? ++count),levels);
 if(actual != expected) throw new Exception($"{thread}: expected {expected}, actual {actual}");
}
Check("A",70,100,null);
Check("A",80,100,20);
Check("A",81,100,null);
Check("B",91,100,10);
Check("A",90,100,10);
Check("A",95,100,5);
Check("A",97,100,null);
Check("B",92,100,null);
Check("A",40,100,null); // compaction recovery
Check("A",96,100,5); // direct jump -> one alert
Check("A",96,100,null);
Check("A",40,100,null,1); // stale snapshot must not rearm
Check("A",96,100,null);
Check("C",0,0,null);
Check("C",-1,100,null);
Check("D",98,100,5);
Check("D",94,100,null); // 1-point jitter must not rearm
Check("D",96,100,null);
Console.WriteLine("PASS: 18 threshold, thread, recovery, stale-data and unknown-window checks.");
