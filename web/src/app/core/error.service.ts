import { Injectable } from '@angular/core';
import { BehaviorSubject, Observable } from 'rxjs';

import { ApiError } from './models';

@Injectable({ providedIn: 'root' })
export class ErrorService {
  private readonly errorSubject = new BehaviorSubject<ApiError | null>(null);
  readonly error$: Observable<ApiError | null> = this.errorSubject.asObservable();

  show(error: ApiError): void {
    this.errorSubject.next(error);
  }

  clear(): void {
    this.errorSubject.next(null);
  }
}