import { DatePipe, NgFor, NgIf } from '@angular/common';
import { Component, OnInit } from '@angular/core';

import { SpinnerComponent } from '../core/spinner.component';
import { UserTask } from '../core/models';
import { ZeebeService } from '../core/zeebe.service';
import { TaskFormComponent } from './task-form.component';

@Component({
  selector: 'app-task-list',
  standalone: true,
  imports: [DatePipe, NgFor, NgIf, SpinnerComponent, TaskFormComponent],
  template: `
    <div class="page-header">
      <h1>Tasks</h1>
      <button type="button" class="btn btn-secondary" (click)="refresh()">Refresh</button>
    </div>

    <app-spinner *ngIf="loading"></app-spinner>

    <ng-container *ngIf="!loading">
      <div class="table-wrap" *ngIf="tasks.length > 0; else emptyState">
        <table class="table">
          <thead>
            <tr>
              <th>Task</th>
              <th>Element</th>
              <th>Candidate Groups</th>
              <th>Process Instance</th>
              <th>Created</th>
            </tr>
          </thead>
          <tbody>
            <tr
              *ngFor="let task of tasks"
              class="task-row"
              data-test="task-row"
              (click)="openTask(task)"
            >
              <td>{{ task.name }}</td>
              <td>{{ task.elementId }}</td>
              <td>{{ task.candidateGroups.join(', ') }}</td>
              <td>{{ task.processInstanceKey }}</td>
              <td>{{ task.creationDate | date: 'medium' }}</td>
            </tr>
          </tbody>
        </table>
      </div>
      <ng-template #emptyState>
        <p class="empty">No open tasks.</p>
      </ng-template>
    </ng-container>

    <div class="modal-backdrop" *ngIf="selectedTask" (click)="closeTask()">
      <div class="modal" (click)="$event.stopPropagation()">
        <app-task-form [task]="selectedTask" (completed)="onTaskCompleted()" (closed)="closeTask()"></app-task-form>
      </div>
    </div>
  `,
  styles: [
    `
      .page-header {
        display: flex;
        align-items: center;
        justify-content: space-between;
        margin-bottom: 20px;
      }
      .page-header h1 {
        margin: 0;
        font-size: 22px;
        color: #1a2b3c;
      }
      .empty {
        color: #6b7280;
        padding: 24px 0;
      }
      .task-row {
        cursor: pointer;
      }
      .task-row:hover {
        background: #f8fafc;
      }
      .modal-backdrop {
        position: fixed;
        inset: 0;
        background: rgba(0, 0, 0, 0.45);
        display: flex;
        align-items: center;
        justify-content: center;
        z-index: 900;
      }
      .modal {
        background: #fff;
        border-radius: 8px;
        width: 560px;
        max-width: 92vw;
        max-height: 88vh;
        overflow-y: auto;
      }
    `,
  ],
})
export class TaskListComponent implements OnInit {
  loading = true;
  tasks: UserTask[] = [];
  selectedTask: UserTask | null = null;

  constructor(private readonly zeebe: ZeebeService) {}

  ngOnInit(): void {
    this.refresh();
  }

  refresh(): void {
    this.loading = true;
    this.zeebe.searchUserTasks({ state: 'CREATED' }).subscribe({
      next: (res) => {
        this.tasks = res.items;
        this.loading = false;
      },
      error: () => {
        this.loading = false;
      },
    });
  }

  openTask(task: UserTask): void {
    this.selectedTask = task;
  }

  onTaskCompleted(): void {
    this.closeTask();
    this.refresh();
  }

  closeTask(): void {
    this.selectedTask = null;
  }
}