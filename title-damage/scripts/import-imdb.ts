/** Offline IMDb non-commercial dataset importer.
 * Usage: npx tsx scripts/import-imdb.ts /path/title.basics.tsv.gz /path/title.ratings.tsv.gz
 * Downloads (manual): https://datasets.imdbws.com/title.basics.tsv.gz and title.ratings.tsv.gz
 * Only import/use data to the extent permitted under IMDb's non-commercial dataset terms.
 * Streaming approach keeps memory usage manageable for basics (~10M rows).
 */
import {createReadStream,writeFileSync} from 'node:fs';import {createGunzip} from 'node:zlib';import {createInterface} from 'node:readline';
import {resolve} from 'node:path';
async function* lines(path:string){const reader=createInterface({input:createReadStream(path).pipe(createGunzip()),crlfDelay:Infinity});for await(const line of reader)yield line}
const basics=process.argv[2],ratings=process.argv[3];if(!basics||!ratings)throw new Error('Provide both IMDb .tsv.gz file paths');
const votes=new Map<string,{score:number;count:number}>();for await(const line of lines(ratings)){const [id,score,count]=line.split('\t');if(+count>=1500)votes.set(id,{score:+score,count:+count})}
const rows:any[]=[];
for await(const line of lines(basics)){const [id,type,title,,adult,year,,runtime,genres]=line.split('\t');const popularity=votes.get(id);if(type!=='movie'||adult!=='0'||!popularity||+year<1950||+year>2026||title==='\\N'||runtime==='\\N'||+runtime<65)continue;
rows.push({id,title,year:+year,language:'und',industry:'Hollywood',genres:genres==='\\N'?[]:genres.split(','),popularity_tier:popularity.count>=100000?1:popularity.count>=15000?2:3,humor_score:Math.max(1,Math.min(5,title.trim().split(/\s+/).length<=7?4:2)),normalized_title:title.normalize('NFKD').toLowerCase().replace(/[^\p{L}\p{N}]/gu,''),external_id:id,family_friendly:false,_votes:popularity.count});}
rows.sort((a,b)=>b._votes-a._votes);const dedup=new Set();const selected=[];for(const row of rows){const key=`${row.normalized_title}|${row.year}`;if(dedup.has(key))continue;dedup.add(key);delete row._votes;selected.push(row);if(selected.length>=2500)break;}
writeFileSync(resolve('data/movies.imdb.json'),JSON.stringify(selected,null,2));console.log(`Created ${selected.length} candidate records in data/movies.imdb.json. Review industry/language/film suitability/family ratings before merging into movies.json. Do not auto-label these Hollywood/family-friendly without enrichment.`)
