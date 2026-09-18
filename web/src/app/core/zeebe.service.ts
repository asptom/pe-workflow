import { Injectable } from '@angular/core';
import { Observable } from 'rxjs';

import { ApiService } from './api.service';
import {
  FormSchemaResponse,
  PageRequest,
  ProcessDefinitionFilter,
  ProcessDefinitionSearchResponse,
  ProcessInstance,
  ProcessInstanceFilter,
  ProcessInstanceSearchResponse,
  SequenceFlowSearchResponse,
  SortRequest,
  StartProcessInstanceResponse,
  UserTaskFilter,
  UserTaskSearchResponse,
  VariableSearchResponse,
  XmlResponse,
} from './models';

@Injectable({ providedIn: 'root' })
export class ZeebeService {
  constructor(private readonly api: ApiService) {}

  searchProcessInstances(
    filter: Partial<ProcessInstanceFilter> = {},
    sort: SortRequest[] = [{ field: 'startDate', order: 'desc' }],
    page: PageRequest = { limit: 50 },
  ): Observable<ProcessInstanceSearchResponse> {
    return this.api.post<ProcessInstanceSearchResponse>('/api/process-instances', { filter, sort, page });
  }

  startProcessInstance(
    processDefinitionKey: string,
    variables: Record<string, unknown>,
    tenantId?: string,
  ): Observable<StartProcessInstanceResponse> {
    const body: Record<string, unknown> = { processDefinitionKey, variables };
    if (tenantId) {
      body['tenantId'] = tenantId;
    }
    return this.api.post<StartProcessInstanceResponse>('/api/process-instances/start', body, {
      broadcastError: false,
    });
  }

  getProcessInstance(key: string): Observable<ProcessInstance> {
    return this.api.get<ProcessInstance>(`/api/process-instances/${key}`);
  }

  getSequences(key: string): Observable<SequenceFlowSearchResponse> {
    return this.api.get<SequenceFlowSearchResponse>(`/api/process-instances/${key}/sequences`);
  }

  searchVariables(key: string): Observable<VariableSearchResponse> {
    return this.api.post<VariableSearchResponse>(`/api/process-instances/${key}/variables`, {
      page: { limit: 100 },
    });
  }

  searchProcessDefinitions(
    filter: Partial<ProcessDefinitionFilter> = {},
    page: PageRequest = { limit: 50 },
  ): Observable<ProcessDefinitionSearchResponse> {
    return this.api.post<ProcessDefinitionSearchResponse>('/api/process-definitions', {
      filter,
      sort: [{ field: 'version', order: 'desc' }],
      page,
    });
  }

  getProcessXml(key: string): Observable<XmlResponse> {
    return this.api.get<XmlResponse>(`/api/process-definitions/${key}/xml`);
  }

  getStartForm(key: string): Observable<FormSchemaResponse | null> {
    return this.api.get<FormSchemaResponse>(`/api/process-definitions/${key}/form`);
  }

  searchUserTasks(
    filter: Partial<UserTaskFilter> = {},
    sort: SortRequest[] = [{ field: 'creationDate', order: 'asc' }],
    page: PageRequest = { limit: 50 },
  ): Observable<UserTaskSearchResponse> {
    return this.api.post<UserTaskSearchResponse>('/api/user-tasks', { filter, sort, page });
  }

  getTaskForm(key: string): Observable<FormSchemaResponse | null> {
    return this.api.get<FormSchemaResponse>(`/api/user-tasks/${key}/form`);
  }

  completeTask(key: string, variables: Record<string, unknown>): Observable<Record<string, never>> {
    return this.api.post<Record<string, never>>(`/api/user-tasks/${key}/completion`, { variables }, {
      broadcastError: false,
    });
  }
}