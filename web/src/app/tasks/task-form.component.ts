import { NgIf } from '@angular/common';
import { Component, EventEmitter, Input, OnInit, Output } from '@angular/core';
import { Observable } from 'rxjs';

import { SpinnerComponent } from '../core/spinner.component';
import { UserTask } from '../core/models';
import { ZeebeService } from '../core/zeebe.service';
import { FormModalComponent } from '../shared/form-modal.component';

@Component({
  selector: 'app-task-form',
  standalone: true,
  imports: [NgIf, SpinnerComponent, FormModalComponent],
  template: `
    <app-spinner *ngIf="!schemaJson && !loadError"></app-spinner>
    <div class="load-error" *ngIf="loadError">{{ loadError }}</div>
    <app-form-modal
      *ngIf="schemaJson"
      [title]="task.name"
      [schemaJson]="schemaJson"
      [submitLabel]="'Complete Task'"
      [submitHandler]="submitHandler"
      (submitted)="completed.emit()"
      (dismissed)="closed.emit()"
    ></app-form-modal>
  `,
  styles: [
    `
      .load-error {
        background: #fef2f2;
        border: 1px solid #fecaca;
        color: #b91c1c;
        border-radius: 6px;
        padding: 10px 12px;
        margin: 16px;
        font-size: 14px;
      }
    `,
  ],
})
export class TaskFormComponent implements OnInit {
  @Input() task!: UserTask;
  @Output() completed = new EventEmitter<void>();
  @Output() closed = new EventEmitter<void>();

  schemaJson: string | null = null;
  loadError: string | null = null;

  constructor(private readonly zeebe: ZeebeService) {}

  ngOnInit(): void {
    this.zeebe.getTaskForm(this.task.userTaskKey).subscribe({
      next: (res) => {
        if (res?.schema) {
          this.schemaJson = res.schema;
        } else {
          this.loadError = 'No form is available for this task.';
        }
      },
      error: (e) => {
        this.loadError = e.message;
      },
    });
  }

  submitHandler = (data: Record<string, unknown>): Observable<unknown> => {
    return this.zeebe.completeTask(this.task.userTaskKey, this.buildPayload(data));
  };

  private buildPayload(data: Record<string, unknown>): Record<string, unknown> {
    if (this.task.elementId === 'UserTask_855A_SiteVisit' && 'siteVerified' in data) {
      return { ...data, siteVisitOutcome: data['siteVerified'] ? 'Passed' : 'Not Passed' };
    }
    return data;
  }
}