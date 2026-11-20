import {test,expect} from '@playwright/test';
test('homepage displays join and host actions',async({page})=>{await page.goto('/');await expect(page.getByText('TITLE',{exact:true})).toBeVisible();await expect(page.getByRole('button',{name:/create game/i})).toBeVisible();await expect(page.getByPlaceholder('ROOM CODE')).toBeVisible()});
test('room join page has nickname input',async({page})=>{await page.goto('/join/XKTM');await expect(page.getByLabel('Your nickname')).toBeVisible()});
