export type Phase='LOBBY'|'REVEAL'|'SUBMITTING'|'SUBMISSION_REVEAL'|'VOTING'|'RESULTS'|'LEADERBOARD'|'FINALE_REVEAL'|'FINALE_VOTING'|'FINALE_RESULTS'|'FINISHED';
export type Settings={rounds:3|5|10;submissionSeconds:20|30|45|60;votingSeconds:15|20|30;category:string;contentMode:'family'|'adult';finale:boolean;sound:boolean};
export const defaults:Settings={rounds:5,submissionSeconds:30,votingSeconds:20,category:'All Movies',contentMode:'family',finale:true,sound:true};
export type Player={id:string;nickname:string;score:number;connected:boolean};
export type Entry={id:string;title:string;author?:string;votes?:number;roundNumber?:number;original?:string;isOwn?:boolean};
export type RoomView={code:string;phase:Phase;deadline:string|null;serverTime:string;settings:Settings;players:Player[];roundNumber:number;movie:string|null;submissionsReceived:number;votesReceived:number;eligibleVoters:number;entries:Entry[];myPlayerId?:string;mySubmitted:boolean;myVoted:boolean;isHost:boolean;winnerIds:string[];finaleWinnerIds:string[];historyRemaining:number|null;paused:boolean};
export const movieParts=(title:string)=>title.trim().split(/\s+/u);
export function insertWord(title:string,index:number,word:string){const parts=movieParts(title);if(!Number.isInteger(index)||index<0||index>parts.length)throw new Error('Invalid insertion position');validateWord(word);const output=[...parts];output.splice(index,0,word);return output.join(' ')}
export function validateWord(word:string){if(typeof word!=='string'||word.length>40||!(/^[\p{L}\p{M}\p{N}][\p{L}\p{M}\p{N}'’\-]*$/u.test(word))||Array.from(word).length>24)throw new Error('Enter exactly one word (letters, numbers, apostrophe or hyphen).');return word;}
export function points(votes:number,maxVotes:number,winners:number){return votes*100+(maxVotes>0&&votes===maxVotes?200/winners:0)}
export function winners<T extends {votes:number}>(entries:T[]){const max=Math.max(0,...entries.map(e=>e.votes));return max===0?[]:entries.filter(e=>e.votes===max)}

/** Parse a fully typed movie title into exactly one inserted word.
 * The original title is never accepted as rewritten; only its whitespace and casing may vary.
 * The server still receives only the insertion index and validated word.
 */
export function parseRuinedTitle(original:string,edited:string):{word:string;index:number}{
 const base=movieParts(original), candidate=edited.trim().split(/\s+/u);
 if(candidate.length!==base.length+1)throw new Error('Add exactly ONE word to the original title.');
 for(let index=0;index<candidate.length;index++){
  const remainder=candidate.filter((_,j)=>j!==index);
  if(remainder.every((part,j)=>part.toLocaleLowerCase()===base[j].toLocaleLowerCase())){
   validateWord(candidate[index]);
   return {word:candidate[index],index};
  }
 }
 throw new Error('Keep every original word in the same order, and add only one new word.');
}
