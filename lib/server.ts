import 'server-only';
import {createClient} from '@supabase/supabase-js';
import {createHash,randomBytes} from 'node:crypto';
export function db(){const url=process.env.NEXT_PUBLIC_SUPABASE_URL,key=process.env.SUPABASE_SERVICE_ROLE_KEY;if(!url||!key)throw new Error('Supabase environment variables are not set');return createClient(url,key,{auth:{persistSession:false,autoRefreshToken:false}})}
export const token=()=>randomBytes(32).toString('base64url');
export const hash=(s:string)=>createHash('sha256').update(s).digest('hex');
export const code=()=>Array.from(randomBytes(4)).map(n=>'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'[n%32]).join('');
export const roomCookie=(code:string,role:'host'|'player')=>`td_${role}_${code}`;
export async function rpc<T=unknown>(name:string,args:Record<string,unknown>):Promise<T>{const {data,error}=await db().rpc(name,args);if(error)throw new Error(error.message);return data as T}
export function errorStatus(msg:string){if(/not found|expired/i.test(msg))return 404;if(/full|already|duplicate|taken|invalid|deadline|not eligible|forbidden|not allowed|too few|no contest|phase|paused/i.test(msg))return 409;return 400}
