import { Component } from '@angular/core';

@Component({
  selector: 'app-spinner',
  standalone: true,
  template: ` <div class="spinner" role="status" aria-label="Loading"></div> `,
  styles: [
    `
      .spinner {
        width: 32px;
        height: 32px;
        border: 4px solid rgba(26, 43, 60, 0.15);
        border-top-color: #1a2b3c;
        border-radius: 50%;
        animation: spin 0.8s linear infinite;
        margin: 24px auto;
      }
      @keyframes spin {
        to {
          transform: rotate(360deg);
        }
      }
    `,
  ],
})
export class SpinnerComponent {}