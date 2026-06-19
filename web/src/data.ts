import { Pursuit } from './types';

export const mockPursuits: Pursuit[] = [
{
  id: 'p1',
  name: 'AWS Certified Solutions Architect',
  type: 'certification',
  status: 'in_progress',
  description: 'Associate level certification for AWS cloud architecture.',
  target_date: new Date(Date.now() + 14 * 24 * 60 * 60 * 1000).toISOString(), // 14 days from now
  started_at: new Date(Date.now() - 30 * 24 * 60 * 60 * 1000).toISOString(), // 30 days ago
  tags: ['cloud', 'aws', 'architecture'],
  milestones: [
  {
    id: 'm1',
    name: 'Complete Cloud Practitioner',
    date: new Date(Date.now() - 20 * 24 * 60 * 60 * 1000).toISOString(),
    state: 'achieved',
    achieved_at: new Date(
      Date.now() - 21 * 24 * 60 * 60 * 1000
    ).toISOString()
  },
  {
    id: 'm2',
    name: 'Finish A Cloud Guru Course',
    date: new Date(Date.now() - 5 * 24 * 60 * 60 * 1000).toISOString(),
    state: 'achieved',
    achieved_at: new Date(
      Date.now() - 4 * 24 * 60 * 60 * 1000
    ).toISOString()
  },
  {
    id: 'm3',
    name: 'Pass Practice Exam 1',
    date: new Date(Date.now() + 2 * 24 * 60 * 60 * 1000).toISOString(),
    state: 'pending'
  },
  {
    id: 'm4',
    name: 'Book Exam',
    date: new Date(Date.now() + 7 * 24 * 60 * 60 * 1000).toISOString(),
    state: 'pending'
  }]

},
{
  id: 'p2',
  name: 'Advanced Kubernetes Patterns',
  type: 'training',
  status: 'in_progress',
  description: 'Deep dive into K8s operators and custom resources.',
  target_date: new Date(Date.now() - 2 * 24 * 60 * 60 * 1000).toISOString(), // 2 days ago (overdue)
  started_at: new Date(Date.now() - 45 * 24 * 60 * 60 * 1000).toISOString(),
  tags: ['kubernetes', 'devops'],
  milestones: [
  {
    id: 'm5',
    name: 'Module 1: Architecture',
    date: new Date(Date.now() - 40 * 24 * 60 * 60 * 1000).toISOString(),
    state: 'achieved',
    achieved_at: new Date(
      Date.now() - 39 * 24 * 60 * 60 * 1000
    ).toISOString()
  },
  {
    id: 'm6',
    name: 'Module 2: Operators',
    date: new Date(Date.now() - 20 * 24 * 60 * 60 * 1000).toISOString(),
    state: 'pending'
  },
  {
    id: 'm7',
    name: 'Final Lab',
    date: new Date(Date.now() - 5 * 24 * 60 * 60 * 1000).toISOString(),
    state: 'pending'
  }]

},
{
  id: 'p3',
  name: 'Certified Information Systems Security Professional',
  type: 'certification',
  status: 'planned',
  target_date: new Date(Date.now() + 180 * 24 * 60 * 60 * 1000).toISOString(),
  started_at: new Date(Date.now() + 30 * 24 * 60 * 60 * 1000).toISOString(),
  tags: ['security', 'cissp'],
  milestones: [
  {
    id: 'm8',
    name: 'Buy Study Guide',
    date: new Date(Date.now() + 35 * 24 * 60 * 60 * 1000).toISOString(),
    state: 'pending'
  },
  {
    id: 'm9',
    name: 'Complete Domain 1-4',
    date: new Date(Date.now() + 90 * 24 * 60 * 60 * 1000).toISOString(),
    state: 'pending'
  }]

},
{
  id: 'p4',
  name: 'React Performance Tuning',
  type: 'training',
  status: 'completed',
  target_date: new Date(Date.now() - 60 * 24 * 60 * 60 * 1000).toISOString(),
  started_at: new Date(Date.now() - 90 * 24 * 60 * 60 * 1000).toISOString(),
  completed_at: new Date(Date.now() - 65 * 24 * 60 * 60 * 1000).toISOString(),
  tags: ['frontend', 'react'],
  milestones: [
  {
    id: 'm10',
    name: 'Profiler Deep Dive',
    date: new Date(Date.now() - 80 * 24 * 60 * 60 * 1000).toISOString(),
    state: 'achieved',
    achieved_at: new Date(
      Date.now() - 82 * 24 * 60 * 60 * 1000
    ).toISOString()
  },
  {
    id: 'm11',
    name: 'Memoization Lab',
    date: new Date(Date.now() - 70 * 24 * 60 * 60 * 1000).toISOString(),
    state: 'achieved',
    achieved_at: new Date(
      Date.now() - 68 * 24 * 60 * 60 * 1000
    ).toISOString()
  }]

}];
