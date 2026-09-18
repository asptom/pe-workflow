import { Component } from '@angular/core';
import { RouterLink, RouterLinkActive } from '@angular/router';

@Component({
  selector: 'app-navigation',
  standalone: true,
  imports: [RouterLink, RouterLinkActive],
  template: `
    <nav class="topbar">
      <div class="topbar-inner">
        <a class="brand" routerLink="/">PE Workflow</a>
        <div class="links">
          <a routerLink="/" routerLinkActive="active" [routerLinkActiveOptions]="{ exact: true }">Dashboard</a>
          <a routerLink="/tasks" routerLinkActive="active">Tasks</a>
        </div>
      </div>
    </nav>
  `,
  styles: [
    `
      .topbar {
        background: #1a2b3c;
        color: #fff;
        box-shadow: 0 1px 3px rgba(0, 0, 0, 0.2);
      }
      .topbar-inner {
        max-width: 1200px;
        margin: 0 auto;
        padding: 0 16px;
        height: 56px;
        display: flex;
        align-items: center;
        gap: 24px;
      }
      .brand {
        color: #fff;
        font-weight: 600;
        font-size: 18px;
        text-decoration: none;
      }
      .links {
        display: flex;
        gap: 16px;
      }
      .links a {
        color: #cbd5e1;
        text-decoration: none;
        padding: 6px 10px;
        border-radius: 4px;
      }
      .links a:hover {
        color: #fff;
      }
      .links a.active {
        color: #fff;
        background: rgba(255, 255, 255, 0.12);
      }
    `,
  ],
})
export class NavigationComponent {}