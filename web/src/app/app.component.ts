import { Component } from '@angular/core';
import { RouterOutlet } from '@angular/router';

import { ErrorDialogComponent } from './core/error-dialog.component';
import { NavigationComponent } from './core/navigation.component';

@Component({
  selector: 'app-root',
  standalone: true,
  imports: [RouterOutlet, NavigationComponent, ErrorDialogComponent],
  template: `
    <app-navigation></app-navigation>
    <main class="container">
      <router-outlet></router-outlet>
    </main>
    <app-error-dialog></app-error-dialog>
  `,
  styles: [
    `
      :host {
        display: block;
        min-height: 100vh;
        background: #f3f4f6;
      }
      .container {
        max-width: 1200px;
        margin: 0 auto;
        padding: 24px 16px;
      }
    `,
  ],
})
export class AppComponent {}