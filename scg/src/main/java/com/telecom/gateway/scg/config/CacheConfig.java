package com.telecom.gateway.scg.config;

import com.github.benmanes.caffeine.cache.Caffeine;
import org.springframework.cache.CacheManager;
import org.springframework.cache.annotation.EnableCaching;
import org.springframework.cache.caffeine.CaffeineCacheManager;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;

import java.util.concurrent.TimeUnit;

@Configuration
@EnableCaching
public class CacheConfig {
    @Bean
    public CacheManager cacheManager() {
        CaffeineCacheManager cacheManager = new CaffeineCacheManager();
        cacheManager.setCaffeine(caffeineCacheBuilder());
        return cacheManager;
    }

    Caffeine<Object, Object> caffeineCacheBuilder() {
        return Caffeine.newBuilder()
                .initialCapacity(100)   //초기 캐시 크기: 몇개의 항목을 수용할 것인가?
                .maximumSize(500)       //최대 캐시 크기
                .expireAfterAccess(10, TimeUnit.MINUTES)    //캐시 제거 기준 시간: 마지막 접근 후 몇분동안 접근 없으면 삭제할 것인가?
                .weakKeys()     //캐시에 저장되는 각 항목에 대해 약한 참조로 설정. 어떤 항목을 참조하는 외부 객체가 사라지면 캐시에서도 그 항목이 사라지게 함
                .recordStats(); //캐시 통계 기록
    }
}
