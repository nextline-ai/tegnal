import 'dart:convert';

/// A small deck course in one file, as the 코스 tab imports it: one season of two episodes (the iOS `LabTests.courseFile`).
List<int> labCourseFile({String id = 'maker.prompt-basics', void Function(Map<String, Object?> top)? edit}) {
  Map<String, Object?> episode(String id, int number) => {
    'id': id,
    'number': number,
    'title': '제목 $number',
    'impact': 10,
    'reward': 999,
    'disaster': {'ask': '질문', 'reply': '답', 'verdict': '판정', 'question': '어떻게 할까요?'},
    'choices': [
      {'text': '맞는 길', 'right': true, 'verdict': '좋아요'},
      {
        'text': '함정',
        'verdict': '아쉬워요',
        'fail': {'id': '$id-trap', 'name': '망작', 'reply': '엉망인 답'},
      },
    ],
    'tool': {
      'kind': 'stamps',
      'title': '도장',
      'stamps': ['맞음', '틀림'],
      'items': [
        {'text': '문장', 'answer': 0},
      ],
    },
    'card': {
      'line': '새길 문장',
      'uses': ['하나', '둘', '셋'],
    },
  };
  final top = <String, Object?>{
    'format': 'tegnal-lab-course',
    'version': 1,
    'id': id,
    'title': '프롬프트 기초',
    'gauge': '실력',
    'base': 20,
    'cardColors': ['1F4D3A', '2B2F77'],
    'seasons': [
      {
        'number': 1,
        'title': '첫 시즌',
        'order': 'fixed',
        'episodes': ['a1', 'a2'],
      },
    ],
    'episodes': [episode('a1', 1), episode('a2', 2)],
  };
  edit?.call(top);
  return utf8.encode(jsonEncode(top));
}

/// A course on the 2D AI course's engine: its own path, under ids of its own, with its own tags (iOS `LabTests.tagsCourseFile`).
List<int> tagsCourseFile({void Function(Map<String, Object?> top)? edit}) {
  final top = <String, Object?>{
    'format': 'tegnal-lab-course',
    'version': 1,
    'engine': 'tags',
    'id': 'maker.backgrounds',
    'title': {'ko': '배경과 장소'},
    'summary': {'ko': '배경을 배웁니다'},
    'color': '2F9E6E',
    'symbol': 'mountain.2',
    'groups': [
      {
        'id': 'places',
        'title': {'ko': '장소'},
        'tags': [
          {'name': 'lighthouse', 'ko': '등대', 'note': {'ko': '바닷가의 등대'}},
        ],
      },
    ],
    'sections': [
      {
        'id': 'one',
        'title': {'ko': '첫 구간'},
        'summary': {'ko': '요약'},
        'color': '2F9E6E',
        'lessons': [
          {
            'id': 'intro',
            'kind': 'concept',
            'symbol': 'book',
            'title': {'ko': '소개'},
            'steps': [
              {'card': {'title': {'ko': '안녕'}, 'body': {'ko': '배경 이야기'}}},
              {
                'ask': {
                  'question': {'ko': '질문'},
                  'choices': [
                    {'ko': '가'},
                    {'ko': '나'},
                  ],
                  'answer': 0,
                  'why': {'ko': '이유'},
                },
              },
            ],
          },
          {
            'id': 'tags',
            'kind': 'tags',
            'symbol': 'tag',
            'title': {'ko': '태그'},
            'tags': ['lighthouse', 'long_hair'],
          },
        ],
      },
    ],
  };
  edit?.call(top);
  return utf8.encode(jsonEncode(top));
}
