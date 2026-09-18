import { DatePipe, NgFor, NgIf } from '@angular/common';
import { Component, OnInit } from '@angular/core';
import { RouterLink } from '@angular/router';
import { Observable } from 'rxjs';

import { SpinnerComponent } from '../core/spinner.component';
import { ApiError, ProcessDefinition, ProcessInstance } from '../core/models';
import { ZeebeService } from '../core/zeebe.service';
import { FormModalComponent } from '../shared/form-modal.component';

@Component({
  selector: 'app-dashboard',
  standalone: true,
  imports: [DatePipe, NgFor, NgIf, RouterLink, SpinnerComponent, FormModalComponent],
  template: `
    <div class="page-header">
      <h1>Dashboard</h1>
      <button type="button" class="btn btn-primary" data-test="start-process" (click)="openStartProcess()">
        Start Process
      </button>
    </div>

    <app-spinner *ngIf="loading"></app-spinner>

    <ng-container *ngIf="!loading">
      <div class="table-wrap" *ngIf="instances.length > 0; else emptyState">
        <table class="table">
          <thead>
            <tr>
              <th>Instance Key</th>
              <th>Process</th>
              <th>BPMN Id</th>
              <th>State</th>
              <th>Started</th>
            </tr>
          </thead>
          <tbody>
            <tr *ngFor="let inst of instances">
              <td>
                <a data-test="process-id" [routerLink]="['/process', inst.processInstanceKey]">{{ inst.processInstanceKey }}</a>
              </td>
               <td>{{ inst.processDefinitionName || inst.processDefinitionId }}</td>
               <td>{{ inst.processDefinitionId }}</td>
              <td><span class="badge" [class.badge-active]="inst.state === 'ACTIVE'">{{ inst.state }}</span></td>
              <td>{{ inst.startDate | date: 'medium' }}</td>
            </tr>
          </tbody>
        </table>
      </div>
      <ng-template #emptyState>
        <p class="empty">No process instances found.</p>
      </ng-template>
    </ng-container>

    <div class="modal-backdrop" *ngIf="showStartModal" (click)="closeStartModal()">
      <div class="modal" (click)="$event.stopPropagation()">
        <ng-container *ngIf="startStep === 'definitions'">
          <div class="modal-header">
            <h2>Start Process</h2>
            <button type="button" class="modal-close" (click)="closeStartModal()" aria-label="Close">×</button>
          </div>
          <div class="modal-body">
            <div class="start-error" *ngIf="startError">{{ startError }}</div>
            <app-spinner *ngIf="loadingDefinitions"></app-spinner>
            <ng-container *ngIf="!loadingDefinitions">
              <label for="definition-select">Process Definition</label>
              <select id="definition-select" (change)="onDefinitionSelected($event)">
                <option value="" disabled selected>Select a process to start…</option>
                 <option *ngFor="let d of definitions" [value]="d.processDefinitionKey">
                   {{ d.name || d.processDefinitionId }} (v{{ d.version }})
                 </option>
              </select>
            </ng-container>
          </div>
        </ng-container>
        <app-form-modal
          *ngIf="startStep === 'form' && startFormSchema"
           [title]="'Start ' + (startDefinition?.name || startDefinition?.processDefinitionId || 'Process')"
          [schemaJson]="startFormSchema"
          [submitLabel]="'Start Process'"
          [submitHandler]="startSubmitHandler"
          (submitted)="onProcessStarted()"
          (dismissed)="closeStartModal()"
        ></app-form-modal>
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
        width: 520px;
        max-width: 92vw;
        max-height: 88vh;
        overflow-y: auto;
      }
      .modal-header {
        display: flex;
        align-items: center;
        justify-content: space-between;
        padding: 16px 20px;
        border-bottom: 1px solid #e5e7eb;
      }
      .modal-header h2 {
        margin: 0;
        font-size: 18px;
        color: #1a2b3c;
      }
      .modal-close {
        background: none;
        border: none;
        font-size: 22px;
        line-height: 1;
        cursor: pointer;
        color: #6b7280;
      }
      .modal-body {
        padding: 20px;
        display: flex;
        flex-direction: column;
        gap: 10px;
      }
      .modal-body label {
        font-weight: 600;
        font-size: 14px;
        color: #374151;
      }
      .start-error {
        background: #fef2f2;
        border: 1px solid #fecaca;
        color: #b91c1c;
        border-radius: 6px;
        padding: 10px 12px;
        margin-bottom: 14px;
        font-size: 14px;
      }
    `,
  ],
})
export class DashboardComponent implements OnInit {
  loading = true;
  instances: ProcessInstance[] = [];

  showStartModal = false;
  startStep: 'definitions' | 'form' | null = null;
  loadingDefinitions = false;
  definitions: ProcessDefinition[] = [];
  startDefinition: ProcessDefinition | null = null;
  startFormSchema: string | null = null;
  startError: string | null = null;

  constructor(private readonly zeebe: ZeebeService) {}

  ngOnInit(): void {
    this.refresh();
  }

  refresh(): void {
    this.loading = true;
    this.zeebe.searchProcessInstances().subscribe({
      next: (res) => {
        this.instances = res.items;
        this.loading = false;
      },
      error: () => {
        this.loading = false;
      },
    });
  }

  openStartProcess(): void {
    this.showStartModal = true;
    this.startStep = 'definitions';
    this.startDefinition = null;
    this.startFormSchema = null;
    this.startError = null;
    this.loadingDefinitions = true;
    this.zeebe.searchProcessDefinitions().subscribe({
      next: (res) => {
        this.definitions = res.items;
        this.loadingDefinitions = false;
      },
      error: () => {
        this.loadingDefinitions = false;
      },
    });
  }

  onDefinitionSelected(event: Event): void {
    const key = (event.target as HTMLSelectElement).value;
    const def = this.definitions.find((d) => d.processDefinitionKey === key);
    if (!def) {
      return;
    }
    this.startDefinition = def;
    this.startError = null;
    if (!def.hasStartForm) {
      this.startWithoutForm();
      return;
    }
    this.zeebe.getStartForm(def.processDefinitionKey).subscribe({
      next: (res) => {
        if (res?.schema) {
          this.startFormSchema = res.schema;
          this.startStep = 'form';
        } else {
          this.startWithoutForm();
        }
      },
      error: () => {
        this.startStep = 'definitions';
      },
    });
  }

  private startWithoutForm(): void {
    const def = this.startDefinition;
    if (!def) {
      return;
    }
    this.zeebe.startProcessInstance(def.processDefinitionKey, {}).subscribe({
      next: () => this.onProcessStarted(),
      error: (e: ApiError) => {
        this.startError = e.message;
      },
    });
  }

  startSubmitHandler = (data: Record<string, unknown>): Observable<unknown> => {
    const def = this.startDefinition;
    if (!def) {
      return new Observable((sub) =>
        sub.error({ status: 0, code: 'internal', message: 'No process definition selected' }),
      );
    }
    return this.zeebe.startProcessInstance(def.processDefinitionKey, data);
  };

  onProcessStarted(): void {
    this.closeStartModal();
    this.refresh();
  }

  closeStartModal(): void {
    this.showStartModal = false;
    this.startStep = null;
    this.startFormSchema = null;
    this.startDefinition = null;
    this.startError = null;
  }
}