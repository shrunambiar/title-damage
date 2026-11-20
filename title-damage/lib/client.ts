'use client';
import {createClient} from '@supabase/supabase-js';
let singleton:ReturnType<typeof createClient>|undefined;
export function realtime(){if(!singleton){singleton=createClient(process.env.NEXT_PUBLIC_SUPABASE_URL!,process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!,{auth:{persistSession:false,autoRefreshToken:false}})}return singleton}
export async function request<T>(path:string,body?:object):Promise<T>{const response=await fetch(path,{method:body?'POST':'GET',headers:{'Content-Type':'application/json'},body:body?JSON.stringify(body):undefined,cache:'no-store'});const value=await response.json();if(!response.ok)throw new Error(value.error||'Request failed');return value as T}
export async function announce(code:string){try{const supabase=realtime();const channel=supabase.getChannels().find(c=>c.topic.endsWith('td:'+code));if(channel)await channel.send({type:'broadcast',event:'changed',payload:{}});else await supabase.channel('td:'+code).send({type:'broadcast',event:'changed',payload:{}})}catch{}}
