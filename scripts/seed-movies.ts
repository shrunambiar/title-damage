import {loadEnvConfig} from '@next/env';
loadEnvConfig(process.cwd());
import {readFileSync} from 'node:fs';import {createClient} from '@supabase/supabase-js';import {resolve} from 'node:path';
const url=process.env.NEXT_PUBLIC_SUPABASE_URL,key=process.env.SUPABASE_SERVICE_ROLE_KEY;if(!url||!key)throw new Error('Configure Supabase environment variables first.');
const movies=JSON.parse(readFileSync(resolve('data/movies.json'),'utf8'));
(async()=>{const db=createClient(url,key,{auth:{persistSession:false}});for(let i=0;i<movies.length;i+=300){const {error}=await db.from('movies').upsert(movies.slice(i,i+300),{onConflict:'id'});if(error)throw error;console.log(`Seeded ${Math.min(i+300,movies.length)}/${movies.length}`)}})().catch(e=>{console.error(e);process.exit(1)});
