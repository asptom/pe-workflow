import { NgIf } from '@angular/common';
import { AfterViewInit, Component, ElementRef, EventEmitter, Input, OnDestroy, Output, ViewChild } from '@angular/core';
import { Form } from '@bpmn-io/form-js-viewer';
import { Observable } from 'rxjs';

import { ErrorService } from '../core/error.service';
import { ApiError } from '../core/models';

@Component({
  selector: 'app-form-modal',
  standalone: true,
  imports: [NgIf],
  template: `
    <div class="form-card">
      <div class="form-card-header">
        <h2>{{ title }}</h2>
      </div>
      <div class="form-card-body">
        <div class="form-error" data-test="form-error" *ngIf="errorMessage">{{ errorMessage }}</div>
        <div #formContainer class="form-container"></div>
      </div>
      <div class="form-card-footer">
        <button type="button" class="btn btn-secondary" [disabled]="submitting" (click)="dismissed.emit()">
          Cancel
        </button>
        <button type="button" class="btn btn-primary" data-test="submit-form" [disabled]="submitting" (click)="onSubmit()">
          {{ submitting ? 'Submitting…' : submitLabel }}
        </button>
      </div>
    </div>
  `,
  styles: [
    `
      .form-card {
        background: #fff;
        border-radius: 8px;
        box-shadow: 0 8px 24px rgba(0, 0, 0, 0.2);
        display: flex;
        flex-direction: column;
        max-height: 85vh;
      }
      .form-card-header {
        padding: 16px 20px;
        border-bottom: 1px solid #e5e7eb;
      }
      .form-card-header h2 {
        margin: 0;
        font-size: 18px;
        color: #1a2b3c;
      }
      .form-card-body {
        padding: 20px;
        overflow-y: auto;
      }
      .form-card-footer {
        padding: 14px 20px;
        border-top: 1px solid #e5e7eb;
        display: flex;
        justify-content: flex-end;
        gap: 10px;
      }
      .form-error {
        background: #fef2f2;
        border: 1px solid #fecaca;
        color: #b91c1c;
        border-radius: 6px;
        padding: 10px 12px;
        margin-bottom: 14px;
        font-size: 14px;
      }
      .form-container {
        min-height: 120px;
      }
    `,
  ],
})
export class FormModalComponent implements AfterViewInit, OnDestroy {
  @Input() title = '';
  @Input() schemaJson = '';
  @Input() submitLabel = 'Submit';
  @Input() submitHandler!: (data: Record<string, unknown>) => Observable<unknown>;
  @Output() submitted = new EventEmitter<void>();
  @Output() dismissed = new EventEmitter<void>();

  @ViewChild('formContainer', { static: true }) formContainer!: ElementRef<HTMLDivElement>;

  form: Form | null = null;
  submitting = false;
  errorMessage: string | null = null;

  constructor(private readonly errorService: ErrorService) {}

  ngAfterViewInit(): void {
    this.renderForm();
  }

  ngOnDestroy(): void {
    this.form?.destroy();
    this.form = null;
  }

  private renderForm(): void {
    let schema: unknown;
    try {
      schema = JSON.parse(this.schemaJson);
    } catch {
      this.errorMessage = 'The form schema could not be parsed.';
      return;
    }
    this.form = new Form({ container: this.formContainer.nativeElement });
    this.form.importSchema(schema).catch(() => {
      this.errorMessage = 'The form schema could not be loaded.';
    });
  }

  async onSubmit(): Promise<void> {
    if (!this.form || this.submitting) {
      return;
    }
    this.errorMessage = null;
    const result = this.form.submit();
    if (result.errors && Object.keys(result.errors).length > 0) {
      this.errorMessage = 'Please fix the highlighted validation errors.';
      return;
    }
    this.submitting = true;
    this.submitHandler(result.data).subscribe({
      next: () => {
        this.submitting = false;
        this.submitted.emit();
      },
      error: (e: ApiError) => {
        this.submitting = false;
        if (e.status === 400) {
          this.errorMessage = e.message;
        } else {
          this.errorService.show(e);
        }
      },
    });
  }
}