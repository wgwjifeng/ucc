/*
1
2
-1
4
-2
-1
7
8
-1
-2
11
-1
13
14
-3
16
17
-1
19
-2
-1
22
23
-1
-2
26
-1
28
29
-3
31
32
-1
34
-2
-1
37
38
-1
-2
41
-1
43
44
-3
46
47
-1
49
-2
-1
52
53
-1
-2
56
-1
58
59
-3
61
62
-1
64
-2
-1
67
68
-1
-2
71
-1
73
74
-3
76
77
-1
79
-2
-1
82
83
-1
-2
86
-1
88
89
-3
91
92
-1
94
-2
-1
97
98
-1
*/
#include "test.h"

int main () {
  int i;
  for (i=1;i<100; ++i) {
    if (i%15==0) {
      print_int(-3);
    } else if (i%3==0) {
      print_int(-1);
    } else if (i%5==0) {
      print_int(-2);
    } else {
      print_int(i);
    }
  }
  return 0;
}
