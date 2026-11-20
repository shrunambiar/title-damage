import {test,expect} from '@playwright/test';
/** Runs against configured Supabase-backed application. Must seed database first. */
test('10 independent players, 11th rejected, 3-round gameplay and finale',async({browser,baseURL})=>{
 test.setTimeout(240000);
 if(!process.env.E2E_LIVE_SUPABASE) test.skip(true,'Set E2E_LIVE_SUPABASE=1 after configuring and seeding Supabase.');
 const host=await browser.newContext();const hostPage=await host.newPage();await hostPage.goto(baseURL!);
 await hostPage.getByRole('button',{name:/create game/i}).click();await hostPage.waitForURL(/\/room\/[A-HJ-NP-Z2-9]{4}/);
 const code=hostPage.url().split('/').at(-1)!;const players=[];
 for(let i=0;i<10;i++){
  const c=await browser.newContext();const page=await c.newPage();await page.goto(`${baseURL}/join/${code}`);
  await page.getByLabel('Your nickname').fill(`Tester${i+1}`);await page.getByRole('button',{name:/join game/i}).click();
  await expect(page.getByText(/you're in/i)).toBeVisible({timeout:15000});players.push({context:c,page});
 }
 await expect(hostPage.getByText('10/10')).toBeVisible();
 const rejected=await browser.newContext();const extra=await rejected.newPage();await extra.goto(`${baseURL}/join/${code}`);
 await extra.getByLabel('Your nickname').fill('Eleventh');await extra.getByRole('button',{name:/join game/i}).click();await expect(extra.getByText(/room full/i)).toBeVisible();
 await hostPage.getByText('Game settings').click();await hostPage.locator('select').first().selectOption('3');
 await hostPage.getByRole('button',{name:/save settings/i}).click();await hostPage.getByRole('button',{name:/start the damage/i}).click();
 for(let round=1;round<=3;round++){
  await expect(hostPage.getByText('TIME TO RUIN IT')).toBeVisible({timeout:30000});
  for(const [i,{page}] of players.entries()){
   await page.getByLabel('Your ONE word').fill(`Banana${i}`);
   await page.getByRole('button',{name:/submit damage/i}).click();
   await expect(page.getByText(/masterpiece submitted/i)).toBeVisible({timeout:15000});
  }
  await expect(hostPage.getByText('THE TITLES HAVE BEEN RUINED')).toBeVisible({timeout:20000});
  await expect(hostPage.getByText('VOTE FOR THE WORST')).toBeVisible({timeout:15000});
  for(const {page} of players){const options=page.locator('button.option');await expect(options.first()).toBeVisible({timeout:15000});await options.first().click();await page.getByRole('button',{name:/cast my vote/i}).click();}
  await expect(hostPage.getByText('THE DAMAGE REPORT')).toBeVisible({timeout:15000});
  await hostPage.getByRole('button',{name:/advance/i}).click(); // RESULTS → LEADERBOARD
  await expect(hostPage.getByText('LEADERBOARD',{exact:true})).toBeVisible({timeout:15000});
  await hostPage.getByRole('button',{name:/advance/i}).click(); // LEADERBOARD → next movie / finale
 }
 await expect(hostPage.getByText(/BEST OF THE NIGHT/).first()).toBeVisible({timeout:30000});
 await expect(hostPage.getByText('THE FINAL VOTE')).toBeVisible({timeout:30000});
 for(const {page} of players){const options=page.locator('button.option');if(await options.count()){await options.first().click();await page.getByRole('button',{name:/cast my vote/i}).click();}}
 await expect(hostPage.getByText(/MOST RUINED MOVIE OF THE NIGHT/)).toBeVisible({timeout:30000});
 await Promise.all(players.map(p=>p.context.close()));await rejected.close();await host.close();
});
