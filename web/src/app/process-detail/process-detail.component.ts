import { DatePipe, NgFor, NgIf } from '@angular/common';
import { Component, ElementRef, OnDestroy, OnInit, ViewChild } from '@angular/core';
import { ActivatedRoute } from '@angular/router';
import BpmnViewer from 'bpmn-js/lib/NavigatedViewer';
import type Canvas from 'diagram-js/lib/core/Canvas';

import { SpinnerComponent } from '../core/spinner.component';
import { ProcessInstance, SequenceFlow, Variable } from '../core/models';
import { ZeebeService } from '../core/zeebe.service';

@Component({
  selector: 'app-process-detail',
  standalone: true,
  imports: [DatePipe, NgFor, NgIf, SpinnerComponent],
  template: `
    <div class="page-header">
      <h1>Process Instance {{ processInstanceKey }}</h1>
    </div>

    <app-spinner *ngIf="loading"></app-spinner>

    <ng-container *ngIf="!loading && instance">
      <div class="meta-grid">
        <div class="meta-card">
          <h3>Instance</h3>
          <dl>
            <dt>Key</dt>
            <dd>{{ instance.processInstanceKey }}</dd>
            <dt>Process</dt>
             <dd>{{ instance.processDefinitionName || instance.processDefinitionId }}</dd>
             <dt>Process Definition Id</dt>
             <dd>{{ instance.processDefinitionId }}</dd>
            <dt>Version</dt>
            <dd>{{ instance.processDefinitionVersion }}</dd>
            <dt>State</dt>
            <dd><span class="badge" [class.badge-active]="instance.state === 'ACTIVE'">{{ instance.state }}</span></dd>
            <dt>Started</dt>
            <dd>{{ instance.startDate | date: 'medium' }}</dd>
            <dt>Ended</dt>
            <dd>{{ (instance.endDate | date: 'medium') ?? '—' }}</dd>
          </dl>
        </div>
        <div class="meta-card">
          <h3>Variables</h3>
          <table class="table table-compact" *ngIf="variables.length > 0; else noVariables">
            <tbody>
              <tr *ngFor="let v of variables">
                <td class="var-name">{{ v.name }}</td>
                <td class="var-value">{{ v.value }}</td>
              </tr>
            </tbody>
          </table>
          <ng-template #noVariables>
            <p class="empty">No variables.</p>
          </ng-template>
        </div>
      </div>

      <div class="diagram-card">
        <h3>Diagram</h3>
        <div #diagram class="diagram"></div>
      </div>

      <div class="timeline-card">
        <h3>Sequence Timeline</h3>
        <ul class="timeline" *ngIf="sequences.length > 0; else noSequences">
          <li *ngFor="let seq of sequences">
            <span class="timeline-date">{{ seq.startDate | date: 'medium' }}</span>
            <span class="timeline-name">{{ seq.elementName || seq.elementId }}</span>
          </li>
        </ul>
        <ng-template #noSequences>
          <p class="empty">No sequence flows recorded yet.</p>
        </ng-template>
      </div>
    </ng-container>
  `,
  styles: [
    `
      .page-header h1 {
        margin: 0 0 20px;
        font-size: 22px;
        color: #1a2b3c;
      }
      .meta-grid {
        display: grid;
        grid-template-columns: 1fr 1fr;
        gap: 16px;
        margin-bottom: 16px;
      }
      .meta-card,
      .diagram-card,
      .timeline-card {
        background: #fff;
        border: 1px solid #e5e7eb;
        border-radius: 8px;
        padding: 16px;
      }
      .meta-card h3,
      .diagram-card h3,
      .timeline-card h3 {
        margin: 0 0 12px;
        font-size: 15px;
        color: #1a2b3c;
      }
      dl {
        display: grid;
        grid-template-columns: 110px 1fr;
        gap: 6px 12px;
        margin: 0;
        font-size: 14px;
      }
      dt {
        color: #6b7280;
      }
      dd {
        margin: 0;
        color: #111827;
        word-break: break-word;
      }
      .var-name {
        font-family: monospace;
        font-size: 13px;
        color: #374151;
        width: 45%;
        word-break: break-all;
      }
      .var-value {
        font-size: 13px;
        color: #111827;
        word-break: break-word;
      }
      .diagram {
        height: 480px;
        border: 1px solid #e5e7eb;
        border-radius: 6px;
        background: #fafafa;
      }
      .timeline {
        list-style: none;
        margin: 0;
        padding: 0;
      }
      .timeline li {
        display: flex;
        gap: 12px;
        padding: 8px 0;
        border-bottom: 1px solid #f3f4f6;
        font-size: 14px;
      }
      .timeline li:last-child {
        border-bottom: none;
      }
      .timeline-date {
        color: #6b7280;
        min-width: 150px;
      }
      .timeline-name {
        color: #111827;
      }
      .empty {
        color: #6b7280;
        margin: 0;
      }
    `,
  ],
})
export class ProcessDetailComponent implements OnInit, OnDestroy {
  processInstanceKey = '';
  instance: ProcessInstance | null = null;
  sequences: SequenceFlow[] = [];
  variables: Variable[] = [];
  loading = true;

  @ViewChild('diagram', { static: false }) diagramEl!: ElementRef<HTMLDivElement>;
  private viewer: BpmnViewer | null = null;

  constructor(
    private readonly route: ActivatedRoute,
    private readonly zeebe: ZeebeService,
  ) {}

  ngOnInit(): void {
    this.processInstanceKey = this.route.snapshot.paramMap.get('processInstanceKey') ?? '';
    this.load();
  }

  ngOnDestroy(): void {
    this.viewer?.destroy();
    this.viewer = null;
  }

  private load(): void {
    this.zeebe.getProcessInstance(this.processInstanceKey).subscribe({
      next: (instance) => {
        this.instance = instance;
        this.loadDiagram(instance.processDefinitionKey);
        this.loadSequences();
        this.loadVariables();
        this.loading = false;
      },
      error: () => {
        this.loading = false;
      },
    });
  }

  private loadDiagram(definitionKey: string): void {
    this.zeebe.getProcessXml(definitionKey).subscribe({
      next: (res) => {
        void this.renderDiagram(res.xml);
      },
      error: () => {
        /* global error dialog handles the failure */
      },
    });
  }

  private async renderDiagram(xml: string): Promise<void> {
    if (!this.diagramEl) {
      return;
    }
    this.viewer = new BpmnViewer({ container: this.diagramEl.nativeElement });
    try {
      await this.viewer.importXML(xml);
      this.viewer.get<Canvas>('canvas').zoom('fit-viewport');
    } catch {
      /* diagram import failure: leave the container empty */
    }
  }

  private loadSequences(): void {
    this.zeebe.getSequences(this.processInstanceKey).subscribe({
      next: (res) => {
        this.sequences = [...res.items].sort((a, b) =>
          (a.startDate ?? '').localeCompare(b.startDate ?? ''),
        );
      },
      error: () => {
        /* global error dialog handles the failure */
      },
    });
  }

  private loadVariables(): void {
    this.zeebe.searchVariables(this.processInstanceKey).subscribe({
      next: (res) => {
        this.variables = res.items;
      },
      error: () => {
        /* global error dialog handles the failure */
      },
    });
  }
}