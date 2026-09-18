export interface ApiError {
  status: number;
  code: string;
  message: string;
}

export interface PageRequest {
  limit?: number;
  after?: string;
  before?: string;
}

export interface PageResponse {
  totalItems?: number;
  startCursor?: string;
  endCursor?: string;
}

export interface SortRequest {
  field: string;
  order: 'asc' | 'desc';
}

export interface DateRange {
  from?: string;
  to?: string;
}

export type ProcessInstanceState = 'ACTIVE' | 'COMPLETED' | 'TERMINATED';

export interface ProcessInstance {
  processInstanceKey: string;
  processDefinitionKey: string;
  processDefinitionName?: string | null;
  processDefinitionId: string;
  processDefinitionVersion: number;
  state: ProcessInstanceState;
  startDate: string;
  endDate?: string | null;
  tenantId?: string;
}

export interface ProcessInstanceFilter {
  processInstanceKey?: string;
  processDefinitionKey?: string;
  processDefinitionId?: string;
  state?: ProcessInstanceState;
  startDate?: DateRange;
  endDate?: DateRange;
}

export interface ProcessInstanceSearchRequest {
  filter: Partial<ProcessInstanceFilter>;
  sort: SortRequest[];
  page: PageRequest;
}

export interface ProcessInstanceSearchResponse {
  items: ProcessInstance[];
  page: PageResponse;
}

export interface StartProcessInstanceRequest {
  processDefinitionKey: string;
  processDefinitionId?: string;
  version?: number;
  variables: Record<string, unknown>;
  tenantId?: string;
}

export interface StartProcessInstanceResponse {
  processInstanceKey: string;
  tenantId: string;
}

export interface SequenceFlow {
  sequenceFlowId: string;
  processInstanceKey?: string;
  processDefinitionKey?: string;
  elementId: string;
  elementName?: string;
  startDate?: string;
  endDate?: string | null;
  tenantId?: string;
}

export interface SequenceFlowSearchResponse {
  items: SequenceFlow[];
  page?: PageResponse;
}

export interface Variable {
  name: string;
  value: string;
  scopeKey?: string;
}

export interface VariableSearchResponse {
  items: Variable[];
  page?: PageResponse;
}

export interface ProcessDefinition {
  processDefinitionKey: string;
  processDefinitionId: string;
  version: number;
  name?: string;
  resourceName: string;
  tenantId: string;
  hasStartForm: boolean;
}

export interface ProcessDefinitionFilter {
  key?: string;
  processDefinitionId?: string;
  version?: number;
  name?: string;
  tenantId?: string;
}

export interface ProcessDefinitionSearchRequest {
  filter: Partial<ProcessDefinitionFilter>;
  sort: SortRequest[];
  page: PageRequest;
}

export interface ProcessDefinitionSearchResponse {
  items: ProcessDefinition[];
  page: PageResponse;
}

export interface XmlResponse {
  xml: string;
}

export interface FormSchemaResponse {
  schema: string;
}

export type UserTaskState = 'CREATED' | 'COMPLETED' | 'CANCELED';

export interface UserTask {
  userTaskKey: string;
  processInstanceKey: string;
  processDefinitionKey?: string;
  bpmnProcessId: string;
  elementId: string;
  name: string;
  state: UserTaskState;
  candidateGroups: string[];
  candidateUsers?: string[];
  assignee?: string | null;
  creationDate?: string;
  completionDate?: string | null;
  tenantId?: string;
}

export interface UserTaskFilter {
  userTaskKey?: string;
  processInstanceKey?: string;
  processDefinitionKey?: string;
  state?: UserTaskState;
  assignee?: string;
  candidateGroup?: string;
  candidateUser?: string;
}

export interface UserTaskSearchRequest {
  filter: Partial<UserTaskFilter>;
  sort: SortRequest[];
  page: PageRequest;
}

export interface UserTaskSearchResponse {
  items: UserTask[];
  page: PageResponse;
}

export interface CompleteUserTaskRequest {
  variables: Record<string, unknown>;
  tenantId?: string;
}