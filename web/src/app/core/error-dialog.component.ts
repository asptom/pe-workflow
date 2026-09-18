import { AsyncPipe, NgIf } from '@angular/common';
import { Component } from '@angular/core';
import { Observable } from 'rxjs';

import { ErrorService } from './error.service';
import { ApiError } from './models';

@Component({
  selector: 'app-error-dialog',
  standalone: true,
  imports: [AsyncPipe, NgIf],
  template: `
    <div class="error-backdrop" *ngIf="error$ | async as error" (click)="dismiss()">
      <div class="error-dialog" role="alertdialog" aria-label="Error" (click)="$event.stopPropagation()">
        <h2>Something went wrong</h2>
        <p class="error-code">{{ error.code }}</p>
        <p class="error-message">{{ error.message }}</p>
        <button class="btn" data-test="error-dismiss" (click)="dismiss()">Dismiss</button>
      </div>
    </div>
  `,
  styles: [
    `
      .error-backdrop {
        position: fixed;
        inset: 0;
        background: rgba(0, 0, 0, 0.45);
        display: flex;
        align-items: center;
        justify-content: center;
        z-index: 1000;
      }
      .error-dialog {
        background: #fff;
        border-radius: 8px;
        padding: 24px;
        max-width: 420px;
        width: 90%;
        box-shadow: 0 8px 24px rgba(0, 0, 0, 0.25);
      }
      .error-dialog h2 {
        margin: 0 0 12px;
        font-size: 18px;
        color: #b91c1c;
      }
      .error-code {
        font-family: monospace;
        font-size: 12px;
        color: #6b7280;
        margin: 0 0 8px;
      }
      .error-message {
        margin: 0 0 20px;
        color: #374151;
        word-break: break-word;
      }
    `,
  ],
})
export class ErrorDialogComponent {
  readonly error$: Observable<ApiError | null>;

  constructor(private readonly errorService: ErrorService) {
    this.error$ = this.errorService.error$;
  }

  dismiss(): void {
    this.errorService.clear();
  }
}