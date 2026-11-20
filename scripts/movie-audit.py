"""Lightweight structural audit independent of node packages; not a fact-check."""
import json,re,sys
from collections import Counter
from pathlib import Path
p=Path(__file__).resolve().parents[1]/'data/movies.json';a=json.loads(p.read_text());ids=set();keys=set();issues=[]
for i,row in enumerate(a):
 for field in ['id','title','year','language','industry','genres','popularity_tier','humor_score','normalized_title']:
  if field not in row:issues.append(f'{i}: missing {field}')
 if row.get('id') in ids:issues.append(f'{i}: duplicate ID')
 ids.add(row.get('id'))
 k=(row.get('normalized_title'),row.get('year'),row.get('language'))
 if k in keys:issues.append(f'{i}: duplicate title/year/language')
 keys.add(k)
 if not (1888<=row.get('year',0)<=2026):issues.append(f'{i}: invalid year')
print(f'{len(a)} records; {len(issues)} structural errors; 2,000+ threshold: {"YES" if len(a)-len(issues)>=2000 else "NO"}')
print('Industry breakdown:',dict(Counter(x['industry'] for x in a)))
for error in issues[:15]:print('ISSUE',error)
sys.exit(bool(issues))
